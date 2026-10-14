// routes-build.mjs — renders worker/jobs/src/routes.gen.js, the jobs worker's
// gated route table, from worker/jobs/test/route-table.d/ (BH-4607).
//
// wrangler.jsonc's build.command runs it before every bundle, so a deploy
// always ships a table made from its own fragments. Node never reads the
// output: package.json "#routes" sends node to test/lib/routes.node.js.
//
//   node scripts/routes-build.mjs              write src/routes.gen.js
//   node scripts/routes-build.mjs --out <path> write <path> instead
//   node scripts/routes-build.mjs --print      write to stdout
//
// Silent with exit 0 on success. On error: one `routes-build: <message>` line
// on stderr, exit 1, and no file written.
import { existsSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseFragments, renderRoutesModule, OPEN_FAMILIES } from "../src/lib/route-families.js";

function main(argv) {
  const here = dirname(fileURLToPath(import.meta.url));
  const fragDir = resolve(here, "../test/route-table.d");
  const srcDir = resolve(here, "../src");
  let out = join(srcDir, "routes.gen.js");
  let print = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--print") print = true;
    else if (argv[i] === "--out") {
      if (!argv[i + 1]) throw new Error("--out needs a path");
      out = resolve(argv[++i]);
    } else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (!existsSync(fragDir)) throw new Error(`no fragment directory: ${fragDir}`);
  const names = readdirSync(fragDir);
  const text = renderRoutesModule(names);
  for (const f of parseFragments(names)) {
    if (OPEN_FAMILIES.has(f.family)) continue;
    if (!existsSync(join(srcDir, "routes", `${f.family}.js`))) {
      throw new Error(`fragment ${f.file} names no src/routes/${f.family}.js`);
    }
  }
  if (print) { process.stdout.write(text); return; }
  // The same bytes: no write, so a re-render does not touch the mtime.
  if (existsSync(out) && readFileSync(out, "utf8") === text) return;
  const tmp = `${out}.${process.pid}.tmp`;
  try {
    writeFileSync(tmp, text);
    renameSync(tmp, out);
  } finally {
    rmSync(tmp, { force: true });
  }
}

// realpath: node resolves symlinks in import.meta.url but not in argv[1].
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(resolve(process.argv[1]))).href) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`routes-build: ${e.message}\n`);
    process.exit(1);
  }
}
