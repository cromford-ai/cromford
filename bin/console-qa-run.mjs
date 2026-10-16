// bin/console-qa-run.mjs — browser QA of a console (Mission Control) PREVIEW
// on Cloudflare Pages, signed in as a READ-ONLY QA session, reporting ONLY what
// was observed (BH-5909 slice 1).
//
//   node console-qa-run.mjs <base-url> <resolve-root> <out-dir> <path> [path...]
//
// env: CONSOLE_QA_TOKEN (required). The hub mints it from the console worker
// (POST /api/qa/session, cromford-console #46). It is used once, in the
// /qa-login/<token> URL, and never printed. The session it buys reads and never
// writes; this driver only loads pages, it never clicks.
//
// Each <path> is loaded at 1440px AND 390px (or at the widths CONSOLE_QA_WIDTHS
// selects, see viewportsFor) through bin/qa-drive.mjs driveScreen
// and judged by its screenFailures, plus horizontal body scroll at 390px. The
// session is proved first: GET <base>/api/dash/fleet must answer 200 after the
// sign-in, or no screen is driven. Prints one line per failure, `SCREEN <path>
// <width> ok|fail` per load, then `QA COVERAGE: screens=<n> flows=0 shots=<n>`
// and `QA: PASS|FAIL`, and exits non-zero on FAIL. playwright is resolved from
// <resolve-root>, then from the global npm root.
//
// A KNOWN PREVIEW GAP is not a defect (BH-6923). The preview environment binds
// nothing, so main's Pages Functions that need CONSOLE_DB, HARNESS_SECRET or
// LEAD_VERDICT_TOKEN answer 503 with their own "<binding> is not set|bound on
// this Pages project" error. Each such same-origin /api/ response prints one
// `PREVIEW GAP: <METHOD> <path> — <binding> not bound in the preview
// environment` line (before QA COVERAGE), and the screen's record loses one
// 503 "Failed to load resource" console error per gap response. Every other
// console error, failed request, HTTP status or scroll still fails.
// observed.json lists each screen as judged: its gap 503s are dropped and
// listed under `gaps`. bin/console-postmerge-qa.sh files findings from it.
//
// The structure is the pool's bin/console-screen-drive.mjs (#5951), moved onto
// the token flow and the 1440/390 widths.
import { mkdirSync, writeFileSync } from "fs";
import { createRequire } from "module";
import { execSync } from "child_process";
import { join } from "path";
import { driveScreen, screenFailures, loadChromium } from "./qa-drive.mjs";

// playwright from <resolve-root>, else the global npm root (the hub installs it
// globally).
function chromiumFrom(resolveRoot) {
  try {
    return loadChromium(resolveRoot);
  } catch {
    const g = execSync("npm root -g", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
    return createRequire(g + "/")("playwright").chromium;
  }
}

export const VIEWPORTS = [
  { name: "1440", width: 1440, height: 900 },
  { name: "390", width: 390, height: 844 },
];

// The heights of the widths a caller may select. bin/console-postmerge-qa.sh
// sets CONSOLE_QA_WIDTHS=1280,375; the preview lane sets nothing.
const HEIGHTS = { 1440: 900, 1280: 900, 390: 844, 375: 812 };

// viewportsFor("1280,375") — the viewports of a comma list of widths, in its
// order. A width not in HEIGHTS is dropped; an empty result is VIEWPORTS.
export function viewportsFor(widths) {
  const out = String(widths || "")
    .split(",")
    .map((w) => w.trim())
    .filter((w) => Object.hasOwn(HEIGHTS, w))
    .map((w) => ({ name: w, width: Number(w), height: HEIGHTS[w] }));
  return out.length ? out : VIEWPORTS;
}

// The verdict for one record at these widths: qa-drive's, plus the 390px body
// scroll (qa-drive only judges scroll at its own 375px).
export function consoleFailures(rec) {
  const out = screenFailures(rec);
  if (rec.viewport === "390" && rec.horizontalScroll) out.push(`${rec.path}@390: horizontal body scroll`);
  return out;
}

const GAP_RE = /^(CONSOLE_DB|HARNESS_SECRET|LEAD_VERDICT_TOKEN) is not (set|bound) on this Pages project/;

// previewGap(status, url, base, body, method) — {key, binding} when the
// response is a known preview gap, else null. Only a 503 from <base>'s own
// origin under /api/ whose JSON error matches GAP_RE counts.
export function previewGap(status, url, base, body, method = "GET") {
  if (status !== 503) return null;
  let u;
  try {
    u = new URL(url);
    if (u.origin !== new URL(base).origin || !u.pathname.startsWith("/api/")) return null;
  } catch {
    return null;
  }
  let err;
  try {
    err = JSON.parse(body).error;
  } catch {
    return null;
  }
  const m = typeof err === "string" ? GAP_RE.exec(err) : null;
  return m ? { key: `${method} ${u.pathname}`, binding: m[1] } : null;
}

// The one formatter of the report line, for main and the tests.
export function previewGapLine(gap) {
  return `PREVIEW GAP: ${gap.key} — ${gap.binding} not bound in the preview environment`;
}

const E503 = "Failed to load resource: the server responded with a status of 503";

// dropGapErrors(rec, n) — a copy of rec without its first n 503 resource
// errors (one per gap response the screen saw). Other errors stay.
export function dropGapErrors(rec, n) {
  if (!(n > 0)) return rec;
  let left = n;
  const consoleErrors = rec.consoleErrors.filter((e) => {
    if (left > 0 && e.startsWith(E503)) {
      left--;
      return false;
    }
    return true;
  });
  return { ...rec, consoleErrors };
}

async function main() {
  const [base, resolveRoot, outDir, ...paths] = process.argv.slice(2);
  const failures = [];
  const screens = [];
  const gaps = new Map();
  const token = process.env.CONSOLE_QA_TOKEN || "";
  const clean = (s) => (token ? String(s).split(token).join("***") : String(s));
  const finish = () => {
    try {
      writeFileSync(join(outDir, "observed.json"), clean(JSON.stringify({ base, paths, screens, failures, gaps: [...gaps.values()] }, null, 2)));
    } catch { /* the printed report is the record of last resort */ }
    for (const f of failures) console.log(clean(`FAIL: ${f}`));
    for (const g of gaps.values()) console.log(clean(g));
    const shots = screens.filter((s) => s.shot).length;
    console.log(`QA COVERAGE: screens=${screens.length} flows=0 shots=${shots}`);
    const pass = failures.length === 0 && screens.length > 0;
    console.log(`QA: ${pass ? "PASS" : "FAIL"}`);
    process.exit(pass ? 0 : 1);
  };
  if (!base || !resolveRoot || !outDir || paths.length === 0) {
    console.log("usage: console-qa-run.mjs <base-url> <resolve-root> <out-dir> <path> [path...]");
    console.log("QA COVERAGE: screens=0 flows=0 shots=0");
    console.log("QA: FAIL");
    process.exit(2);
  }
  mkdirSync(outDir, { recursive: true });
  if (!/^[0-9]+\.[0-9a-f]{64}$/.test(token)) {
    failures.push("CONSOLE_QA_TOKEN is not a QA session token — no screen driven");
    return finish();
  }
  let chromium;
  try {
    chromium = chromiumFrom(resolveRoot);
  } catch {
    failures.push(`playwright not resolvable from ${resolveRoot} or the global npm root`);
    return finish();
  }
  const browser = await chromium.launch();
  try {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(`${base}/qa-login/${token}`, { waitUntil: "domcontentloaded", timeout: 45000 }).catch(() => null);
    await page.close();
    const probe = await ctx.request.get(`${base}/api/dash/fleet`).catch(() => null);
    const pst = probe ? probe.status() : null;
    if (pst !== 200) {
      failures.push(`the QA session did not hold: GET /api/dash/fleet answered ${pst === null ? "no response" : `HTTP ${pst}`} after /qa-login/ — no screen driven`);
      return finish();
    }
    // The gap responses of the screen being driven. Only a /api/ 503 has its
    // body read; a body that does not read is not a gap (fail closed).
    let cur = null;
    ctx.on("response", (r) => {
      if (!cur || r.status() !== 503) return;
      let path;
      try {
        path = new URL(r.url()).pathname;
      } catch {
        return;
      }
      if (!path.startsWith("/api/")) return;
      cur.push(r.text().then((b) => previewGap(r.status(), r.url(), base, b, r.request().method())).catch(() => null));
    });
    const viewports = viewportsFor(process.env.CONSOLE_QA_WIDTHS || "");
    for (const path of paths) {
      for (const viewport of viewports) {
        cur = [];
        const rec = await driveScreen(ctx, { base, path, viewport, outDir });
        const seen = (await Promise.all(cur)).filter(Boolean);
        cur = null;
        for (const g of seen) if (!gaps.has(g.key)) gaps.set(g.key, previewGapLine(g));
        const judged = dropGapErrors(rec, seen.length);
        screens.push(judged);
        const f = consoleFailures(judged);
        failures.push(...f);
        console.log(`SCREEN ${path} ${viewport.name} ${f.length ? "fail" : "ok"}`);
      }
    }
  } catch (e) {
    failures.push(`drive: ${String(e).slice(0, 300)}`);
  } finally {
    await browser.close().catch(() => {});
  }
  return finish();
}

// NOT named *qa-drive.mjs: bin/qa-drive.mjs runs its own main() when argv[1]
// ends with that name, and it is imported here.
if (process.argv[1] && process.argv[1].endsWith("/console-qa-run.mjs")) await main();
