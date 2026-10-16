// bin/qa-drive.mjs — drive a deployed app as a real signed-in QA user and
// report ONLY what was observed.
//
//   node qa-drive.mjs <base-url> <resolve-root> <out-dir> <path> [path...]
//   node qa-drive.mjs <base-url> <resolve-root> <out-dir> [path...] \
//        --flows <scoped.json> [--persona <id>] [--preview|--production]
//
// env: QA_CLERK_SECRET_KEY (required), QA_TEST_USER_ID (required),
//      VERCEL_AUTOMATION_BYPASS_SECRET (optional, previews only)
//
// Every screen is loaded at 1280px AND 375px, screenshotted, and checked for
// the UI iron laws a drive is the only thing that can see. Writes
// <out-dir>/observed.json (the machine-readable record), prints a human summary
// ending with `QA COVERAGE:` and `QA: PASS|FAIL`, and EXITS NON-ZERO ON FAIL.
//
// THREE THINGS THIS FILE IS OPINIONATED ABOUT
//
// 1. A LANDING ON /sign-in IS A FAIL. Never a skip, never a pass with a note.
//    Clerk mints a sign-in ticket for a BANNED user perfectly happily — POST
//    /v1/sign_in_tokens answers 200 — and the refusal only shows up when the
//    browser presents it. The old smoke check printed "FAIL:" and then exited
//    0, so a drive that QA'd nothing but the sign-in page reported success.
//    signIn() throws, the CLI exits 1, and the report says screens=0.
//
// 2. THE BAN IS CHECKED BEFORE THE TICKET IS MINTED, so the failure names its
//    own cause instead of surfacing as a mystery redirect. Lifting the ban is
//    NOT this file's job — bin/qa-unbanned.sh owns that window and its restore.
//
// 3. THE BYPASS IS A COOKIE, NEVER A GLOBAL HEADER. A global extraHTTPHeaders
//    rides along on third-party requests (Clerk's CDN) and breaks their CORS
//    preflight. That lesson cost a full QA stage on 2026-07-28.
//
// playwright is resolved from <resolve-root> via createRequire because ESM
// imports ignore NODE_PATH; pass the product repo that has it installed.
import { createRequire } from "module";
import { mkdirSync, writeFileSync, readFileSync } from "fs";
import { join } from "path";
import { runFlow } from "./lib/qa-flows.mjs";

const CLERK_API = process.env.CLERK_API || "https://api.clerk.com";
const VIEWPORTS = [
  { name: "1280", width: 1280, height: 900 },
  { name: "375", width: 375, height: 812 },
];

export function loadChromium(resolveRoot) {
  const root = resolveRoot.endsWith("/") ? resolveRoot : resolveRoot + "/";
  return createRequire(root)("playwright").chromium;
}

// Reads the user's ban state. Returns true/false, or throws — an unreadable
// state is never reported as "not banned", because that is the reading that
// sends a drive off to QA the sign-in page.
export async function isBanned(userId, clerkKey) {
  const res = await fetch(`${CLERK_API}/v1/users/${userId}`, {
    headers: { Authorization: `Bearer ${clerkKey}` },
  });
  if (!res.ok) throw new Error(`clerk user read HTTP ${res.status}`);
  const user = await res.json();
  if (typeof user.banned !== "boolean") throw new Error("clerk user object has no `banned` field");
  return user.banned;
}

// Lands a real session in `page`. Throws on every path that does not end in a
// signed-in page — including the one that used to be silent.
export async function signIn(page, { base, userId, clerkKey, bypass }) {
  if (await isBanned(userId, clerkKey)) {
    throw new Error(
      `QA user ${userId} is BANNED in Clerk. A ticket would mint and the session would bounce to /sign-in. ` +
        `Drive through bin/qa-unbanned.sh <project> <role> -- <command…>, which lifts the ban and restores it.`,
    );
  }
  if (bypass) {
    // Bypass COOKIE mode, never a global extra header (see header note 3).
    await page.goto(
      `${base}/?x-vercel-protection-bypass=${bypass}&x-vercel-set-bypass-cookie=true`,
      { waitUntil: "domcontentloaded", timeout: 45000 },
    );
  }
  const res = await fetch(`${CLERK_API}/v1/sign_in_tokens`, {
    method: "POST",
    headers: { Authorization: `Bearer ${clerkKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: userId, expires_in_seconds: 300 }),
  });
  if (!res.ok) throw new Error(`sign-in token mint HTTP ${res.status}`);
  const ticket = (await res.json()).token;
  await page.goto(`${base}/sign-in?__clerk_ticket=${encodeURIComponent(ticket)}`, {
    waitUntil: "domcontentloaded",
    timeout: 45000,
  });
  await page.waitForURL((u) => !isAuthWall(u.pathname), { timeout: 30000 });
  await page.waitForTimeout(2000);
  // Belt and braces: waitForURL can be satisfied by a transient URL that
  // redirects straight back. The landed URL is the one that counts.
  const landed = new URL(page.url());
  if (isAuthWall(landed.pathname)) throw new Error(`bounced back to ${landed.pathname}`);
  return page.url();
}

export function isAuthWall(pathname) {
  return pathname.startsWith("/sign-in") || pathname.startsWith("/sign-up");
}

// One screen at one viewport. Returns a record of what was actually seen; it
// never throws for a page-level defect, because a broken screen is a FINDING to
// report, not a reason to abandon the remaining screens.
export async function driveScreen(ctx, { base, path, viewport, outDir }) {
  const record = {
    path,
    viewport: viewport.name,
    url: null,
    status: null,
    landedOnAuthWall: false,
    consoleErrors: [],
    failedRequests: [],
    horizontalScroll: null,
    nativeDialog: null,
    shot: null,
    error: null,
  };
  const page = await ctx.newPage();
  page.setViewportSize({ width: viewport.width, height: viewport.height });
  page.on("console", (m) => {
    if (m.type() === "error" && record.consoleErrors.length < 10) record.consoleErrors.push(m.text().slice(0, 300));
  });
  page.on("requestfailed", (r) => {
    // A request the BROWSER cancelled is not a request the SERVER failed.
    // Next.js aborts its own RSC prefetches (`?_rsc=`) the moment the user
    // navigates on, and playwright reports each one as requestfailed with
    // net::ERR_ABORTED. Counting those failed every project-2 post-merge
    // QA on 2026-09-11/-14 (TK-233, TK-247, TK-253: "1 failed request(s):
    // GET …?_rsc=…") on merges that had nothing to do with those screens.
    // A real failure — DNS, reset, a 5xx read as a network error — keeps a
    // different errorText and is still recorded.
    const why = (r.failure() && r.failure().errorText) || "";
    if (why === "net::ERR_ABORTED") return;
    if (record.failedRequests.length < 10) record.failedRequests.push(`${r.method()} ${r.url().slice(0, 200)} (${why || "failed"})`);
  });
  // A native confirm/alert/prompt would hang a headless run forever. Recording
  // it and dismissing is both the finding and the only way to keep driving.
  page.on("dialog", async (d) => {
    record.nativeDialog = `${d.type()}: ${d.message().slice(0, 200)}`;
    await d.dismiss().catch(() => {});
  });
  try {
    const res = await page.goto(`${base}${path}`, { waitUntil: "domcontentloaded", timeout: 45000 });
    record.status = res ? res.status() : null;
    await page.waitForTimeout(1500);
    record.url = page.url();
    record.landedOnAuthWall = isAuthWall(new URL(record.url).pathname);
    // QA_OVERFLOW_PX (default 4, the qa.overflow_px row) absorbs sub-pixel rounding and a few px
    // of overflow on a non-core screen; anything wider is a real overflow (BH-7123).
    const overflowPx = Number.parseInt(process.env.QA_OVERFLOW_PX || "4", 10) || 4;
    record.horizontalScroll = await page.evaluate(
      (px) => document.documentElement.scrollWidth > document.documentElement.clientWidth + px,
      overflowPx,
    );
    const shot = join(outDir, `${path.replace(/[^a-zA-Z0-9]+/g, "_") || "root"}-${viewport.name}.png`);
    await page.screenshot({ path: shot, fullPage: false });
    record.shot = shot;
  } catch (e) {
    record.error = String(e).slice(0, 300);
  } finally {
    await page.close().catch(() => {});
  }
  return record;
}

// A record's verdict, in one place so the CLI and the tests agree on what
// "observed a defect" means.
export function screenFailures(r) {
  const out = [];
  if (r.error) out.push(`${r.path}@${r.viewport}: ${r.error}`);
  if (r.landedOnAuthWall) out.push(`${r.path}@${r.viewport}: landed on the sign-in wall — the session did not hold`);
  if (typeof r.status === "number" && r.status >= 400) out.push(`${r.path}@${r.viewport}: HTTP ${r.status}`);
  if (r.consoleErrors.length) out.push(`${r.path}@${r.viewport}: ${r.consoleErrors.length} console error(s): ${r.consoleErrors[0]}`);
  if (r.failedRequests.length) out.push(`${r.path}@${r.viewport}: ${r.failedRequests.length} failed request(s): ${r.failedRequests[0]}`);
  if (r.viewport === "375" && r.horizontalScroll) out.push(`${r.path}@375: horizontal body scroll`);
  if (r.nativeDialog) out.push(`${r.path}@${r.viewport}: native browser dialog (${r.nativeDialog})`);
  return out;
}

// The flags may appear anywhere in argv, because the callers that grew them
// (bin/postmerge-qa.sh forwards "$@" after three fixed positionals) append
// rather than insert. With no flag at all the result is exactly today's
// positional reading.
export function parseArgs(argv) {
  const out = { positional: [], flows: null, persona: null, mode: "production" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--flows") { out.flows = argv[++i] ?? null; continue; }
    if (a === "--persona") { out.persona = argv[++i] ?? null; continue; }
    if (a === "--preview") { out.mode = "preview"; continue; }
    if (a === "--production") { out.mode = "production"; continue; }
    out.positional.push(a);
  }
  return out;
}

// Which flows of a scoped persona document this run may drive, in file order.
// The gate is FAIL-CLOSED: only `preview` runs a flow that is not explicitly
// production_safe, so a typo'd mode skips write flows instead of firing them at
// production. Scoping already strips a skipped flow's steps; the `skipped` mark
// is honoured here too so a scoped document and a raw one read the same.
export function selectFlows(scopedDoc, mode = "production", personaId) {
  const rows = [];
  for (const persona of (scopedDoc && scopedDoc.personas) || []) {
    if (personaId && persona.id !== personaId) continue;
    for (const flow of persona.flows || []) {
      const skip = Boolean(flow.skipped) || (mode !== "preview" && flow.production_safe !== true);
      rows.push({ persona: persona.id, flow: flow.id, action: skip ? "skip" : "run", def: flow });
    }
  }
  return rows;
}

// The scoped document, or a reason it cannot be driven. The word NONE is a
// valid scoping output but NOT a valid input here: a lane branches on NONE
// before it ever calls the drive, so reaching us with it is a caller bug worth
// naming rather than a zero-flow pass.
function loadFlowsDoc(path) {
  const raw = readFileSync(path, "utf8");
  if (raw.trim() === "NONE") throw new Error("document is NONE (nothing in scope)");
  const doc = JSON.parse(raw);
  if (!doc || !Array.isArray(doc.personas)) throw new Error("no `personas` array");
  return doc;
}

async function main() {
  const { positional, flows: flowsPath, persona: personaFilter, mode } = parseArgs(process.argv.slice(2));
  const [base, resolveRoot, outDir, ...paths] = positional;
  if (!base || !resolveRoot || !outDir || (paths.length === 0 && !flowsPath)) {
    console.log("usage: qa-drive.mjs <base-url> <resolve-root> <out-dir> <path> [path...]");
    console.log("QA COVERAGE: screens=0 flows=0 shots=0");
    console.log("QA: FAIL");
    process.exit(2);
  }
  const clerkKey = process.env.QA_CLERK_SECRET_KEY;
  const userId = process.env.QA_TEST_USER_ID;
  const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
  const summary = {
    base, paths, mode, signedInAs: userId || null, landed: null, screens: [], flows: [], failures: [],
  };
  mkdirSync(outDir, { recursive: true });

  const finish = (code) => {
    // `flows=` counts what was actually driven — pass plus fail, never a
    // skipped or blocked flow (docs/E2E-POLICY.md line 279).
    const executed = summary.flows.filter((f) => f.verdict === "pass" || f.verdict === "fail").length;
    const shots = summary.screens.filter((s) => s.shot).length +
      summary.flows.reduce((n, f) => n + (f.steps || []).filter((s) => s.shot).length, 0);
    try {
      writeFileSync(join(outDir, "observed.json"), JSON.stringify(summary, null, 2));
    } catch { /* the printed report is the record of last resort */ }
    for (const f of summary.failures) console.log(`FAIL: ${f}`);
    console.log(`QA COVERAGE: screens=${summary.screens.length} flows=${executed} shots=${shots}`);
    console.log(`QA: ${code === 0 ? "PASS" : "FAIL"}`);
    process.exit(code);
  };

  // Before the Clerk env check and before playwright: an unreadable flows file
  // is a caller error, and naming the env instead would send the reader off to
  // the wrong place.
  let flowsDoc = null;
  if (flowsPath) {
    try {
      flowsDoc = loadFlowsDoc(flowsPath);
    } catch (e) {
      summary.failures.push(`flows file ${flowsPath}: ${String(e && e.message ? e.message : e).slice(0, 200)}`);
      return finish(2);
    }
  }

  if (!clerkKey || !userId) {
    summary.failures.push("QA_CLERK_SECRET_KEY / QA_TEST_USER_ID unset — no authed screen was driven");
    return finish(1);
  }

  let chromium;
  try {
    chromium = loadChromium(resolveRoot);
  } catch (e) {
    summary.failures.push(`playwright not resolvable from ${resolveRoot}: ${String(e).slice(0, 160)}`);
    return finish(1);
  }
  const selected = flowsDoc ? selectFlows(flowsDoc, mode, personaFilter) : [];
  if (flowsDoc && personaFilter && selected.length === 0) {
    summary.failures.push(`--persona ${personaFilter} matched no persona in ${flowsPath}`);
  }
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  try {
    const page = await ctx.newPage();
    summary.landed = await signIn(page, { base, userId, clerkKey, bypass });
    console.log(`LANDED:${summary.landed}`);
    await page.close();
    for (const path of paths) {
      for (const viewport of VIEWPORTS) {
        const rec = await driveScreen(ctx, { base, path, viewport, outDir });
        summary.screens.push(rec);
        summary.failures.push(...screenFailures(rec));
      }
    }
    for (const sel of selected) {
      if (sel.action === "skip") {
        summary.flows.push({ persona: sel.persona, flow: sel.flow, verdict: "skipped", steps: [], reason: null });
        console.log(`FLOW ${sel.persona} ${sel.flow} skipped (write flow, production)`);
        continue;
      }
      const rec = await runFlow(ctx, { base, persona: sel.persona, flow: sel.def, outDir });
      summary.flows.push(rec);
      const okCount = rec.steps.filter((s) => s.ok).length;
      const total = Array.isArray(sel.def.steps) ? sel.def.steps.length : rec.steps.length;
      const shots = rec.steps.filter((s) => s.shot);
      const lastShot = shots.length ? shots[shots.length - 1].shot : "-";
      const tail = rec.verdict === "fail" ? ` ${rec.reason}` : "";
      console.log(`FLOW ${sel.persona} ${sel.flow} ${rec.verdict} steps=${okCount}/${total} shot=${lastShot}${tail}`);
      if (rec.verdict === "fail") summary.failures.push(`flow ${sel.persona}/${sel.flow}: ${rec.reason}`);
    }
  } catch (e) {
    // Sign-in failure reaches here. screens stays 0 and the verdict is FAIL —
    // the one outcome that must never be a quiet pass. Every flow that was in
    // scope owes a blocked row, skipped ones included: "nothing ran" covers
    // them too, and a lane that greps for its flow must find it.
    const reason = String(e).slice(0, 300);
    summary.failures.push(`sign-in: ${reason}`);
    for (const sel of selected) {
      summary.flows.push({ persona: sel.persona, flow: sel.flow, verdict: "blocked", steps: [], reason });
      console.log(`FLOW ${sel.persona} ${sel.flow} blocked sign-in: ${reason}`);
    }
  } finally {
    await browser.close().catch(() => {});
  }
  // A flows-only run drives no screens, so "observed something" is screens OR
  // executed flows — and a run where everything was skipped observed nothing,
  // which is not a pass.
  const executed = summary.flows.filter((f) => f.verdict === "pass" || f.verdict === "fail").length;
  finish(summary.failures.length === 0 && (summary.screens.length > 0 || executed > 0) ? 0 : 1);
}

// Only the CLI invocation runs main(); importers (qa-signin-check.mjs, the
// tests) get the functions without a browser launch.
if (process.argv[1] && process.argv[1].endsWith("qa-drive.mjs")) await main();
