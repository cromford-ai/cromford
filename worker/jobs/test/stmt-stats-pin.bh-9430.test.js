// BH-9430: a worker test that diffs the row count of every table must pin
// stmt-stats sampling off. withStmtStats (BH-9076) wraps the default
// worker.fetch, and the schema seeds d1.stmt_stats_sample_pct = '1'. So about
// 1 request in 100 flushes d1_stmt_stats rows, and a "no other table changed"
// invariant fails about 2% of runs (d1-overload-giveup.bh-7541 G3 in the
// merge queue).
//
// P1 runs the real G3 in a child node with Math.random forced to 0: every
// request is then sampled at pct 1, the worst case. With no random input, one
// run is the same as 200 runs.
// G1 scans every worker test and asserts each whole-table diff pins the
// sampler off (the settings row at '0', or a stubbed random for withStmtStats).
// G2 pins the decision rule of that scan, case by case.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(HERE); // worker/jobs
const SELF = fileURLToPath(import.meta.url);
const TARGET = "test/d1-overload-giveup.bh-7541.test.js";

let SQLITE = true;
try { await import("node:sqlite"); } catch { SQLITE = false; }

// isTableDiff(text): the file counts the rows of every table (it lists the
// tables from sqlite_master and counts a table named by a variable), or it
// asserts "no other table changed".
export function isTableDiff(text) {
  const lists = /sqlite_master[^\n]*type\s*=\s*'table'/.test(text);
  const dynCount = /COUNT\(\*\)[^\n]*"\$\{/i.test(text);
  return (lists && dynCount) || /no other table changed/i.test(text);
}

// pinsSampler(text): the file sets d1.stmt_stats_sample_pct to '0' on one
// line (key before value, or SET value = '0' WHERE key = ...), or passes a
// stubbed random to withStmtStats.
export function pinsSampler(text) {
  return /d1\.stmt_stats_sample_pct[^\n]*['"]0['"]/.test(text)
    || /value\s*=\s*['"]0['"][^\n]*key\s*=\s*['"]d1\.stmt_stats_sample_pct['"]/.test(text)
    || /withStmtStats\([^)]*random\s*:/.test(text);
}

function jsFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "node_modules") continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...jsFiles(p));
    else if (e.isFile() && e.name.endsWith(".js")) out.push(p);
  }
  return out;
}

test("P1: G3 of the bh-7541 file passes with Math.random forced to 0 (every request sampled)", { skip: SQLITE ? false : "node:sqlite is absent" }, () => {
  const env = { ...process.env };
  // The parent runner sets this; a child `node --test` would then report to
  // the parent over its own protocol instead of TAP on stdout.
  delete env.NODE_TEST_CONTEXT;
  const r = spawnSync(process.execPath, [
    "--import", "data:text/javascript,Math.random=()=>0",
    "--test", "--test-reporter=tap", "--test-name-pattern=^G3", TARGET,
  ], { cwd: ROOT, env, encoding: "utf8", timeout: 60_000 });
  const out = `${r.stdout || ""}${r.stderr || ""}`;
  const tail = out.split("\n").slice(-40).join("\n");
  assert.equal(r.error, undefined, `child did not run: ${r.error}`);
  assert.equal(r.status, 0, `G3 failed with Math.random = 0:\n${tail}`);
  assert.match(out, /^ok \d+ - G3: /m, `G3 is not reported as passed:\n${tail}`);
  assert.doesNotMatch(out, /^ok \d+ - G3: [^\n]*# SKIP/m, "G3 was skipped");
  assert.match(out, /^# pass 1$/m, `expected exactly 1 passed test:\n${tail}`);
  assert.match(out, /^# fail 0$/m);
});

test("G1: every worker test with a whole-table diff pins stmt-stats sampling off", () => {
  const diffs = jsFiles(HERE)
    .filter((p) => p !== SELF)
    .map((p) => ({ rel: relative(ROOT, p), text: readFileSync(p, "utf8") }))
    .filter(({ text }) => isTableDiff(text));
  const names = diffs.map((d) => d.rel);
  assert.ok(names.length > 0, "the scan matched no table-diff test: the rule matches nothing");
  assert.ok(names.includes(TARGET), `the scan missed ${TARGET}; matched: ${names.join(", ")}`);
  const open = diffs.filter(({ text }) => !pinsSampler(text)).map((d) => d.rel);
  assert.deepEqual(open, [], `table-diff tests that leave d1.stmt_stats_sample_pct sampling on: ${open.join(", ")}`);
});

test("G2: the decision rule, case by case", () => {
  const T = isTableDiff;
  const P = pinsSampler;
  // isTableDiff TRUE
  assert.equal(T(`db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all()
    .map(({ name }) => [name, db.prepare(\`SELECT COUNT(*) AS n FROM "\${name}"\`).get().n]);`), true, "(a) the G3 shape");
  assert.equal(T(`assert.deepEqual(after, before, "no other table changed");`), true, "(b) the assertion text only");
  assert.equal(T(`all("SELECT name FROM sqlite_master WHERE type = 'table'");
    get(\`SELECT count(*) AS n FROM "\${t}"\`);`), true, "(c) spaces and lower-case count");
  // isTableDiff FALSE (near misses)
  assert.equal(T(`all("SELECT name FROM sqlite_master WHERE type='index'");
    get("SELECT COUNT(*) AS n FROM pr_attempts");`), false, "(d) index list, fixed count");
  assert.equal(T(`get("SELECT name FROM sqlite_master WHERE type='table' AND name='merge_trains'");`), false, "(e) one named table");
  assert.equal(T(`get("SELECT COUNT(*) AS c FROM pr_state_events");`), false, "(f) fixed count alone");
  assert.equal(T(`// the route writes no other table here`), false, "(g) 'other table' in a comment");
  // pinsSampler TRUE
  assert.equal(P(`db.exec("UPDATE settings SET value = '0' WHERE key = 'd1.stmt_stats_sample_pct'");`), true, "(h) UPDATE, value before key");
  assert.equal(P(`const rows = [{ key: 'd1.stmt_stats_sample_pct', value: '0' }];`), true, "(i) the bh-9325 stub row");
  assert.equal(P(`const w = withStmtStats(h, { random: () => 1 });`), true, "(j) stubbed random");
  // pinsSampler FALSE
  assert.equal(P(`setting(o.db, 'd1.stmt_stats_sample_pct', 100);`), false, "(k) pct 100");
  assert.equal(P(`('d1.stmt_stats_sample_pct', '1')`), false, "(l) the seed value");
  assert.equal(P(`('d1.stmt_stats_sample_pct', '10')`), false, "(m) '10' is not '0'");
  assert.equal(P(`// d1.stmt_stats_sample_pct is seeded at 1`), false, "(n) the key in a comment, no value");
  assert.equal(P(`const w = withStmtStats(handler);`), false, "(o) no options");
  assert.equal(P(`VALUES ('x','0'), ('d1.stmt_stats_sample_pct','1')`), false, "(p) a '0' of another row before the key");
});
