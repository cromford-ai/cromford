// retention-build.mjs — renders worker/jobs/src/retention-rules.gen.js, the
// rules routes/retention.js imports as `#retention-rules`, from
// worker/jobs/src/routes/retention.d/ (BH-8398.0).
//
// wrangler.jsonc's build.command runs it before every bundle, so a deploy
// always ships the rules made from its own fragments. Node never reads the
// output: package.json "#retention-rules" sends node to
// src/lib/retention-rules.node.js.
//
//   node scripts/retention-build.mjs              write src/retention-rules.gen.js
//   node scripts/retention-build.mjs --out <path> write <path> instead
//   node scripts/retention-build.mjs --print      write to stdout
//
// Silent with exit 0 on success. On error: one `retention-build: <message>`
// line on stderr, exit 1, and no file written.
import { existsSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { checkRules, fragmentNames, fragmentRules, renderRulesModule } from "../src/lib/retention-rules.js";

async function main(argv) {
  const here = dirname(fileURLToPath(import.meta.url));
  const src = resolve(here, "../src");
  const fragDir = join(src, "routes/retention.d");
  let out = join(src, "retention-rules.gen.js");
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
  // Compose under node first: a bad fragment fails here, before any write,
  // not inside the deployed worker.
  const files = fragmentNames(names);
  const mods = await Promise.all(files.map((f) => import(pathToFileURL(join(fragDir, f)).href)));
  checkRules(files.flatMap((f, i) => fragmentRules(f, mods[i])));
  const text = renderRulesModule(names);

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
    await main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`retention-build: ${String(e && e.message || e).split("\n")[0]}\n`);
    process.exit(1);
  }
}
