// core-registries-build.mjs — renders worker/jobs/src/lib/core-registries.gen.js,
// the schema registries core.js imports as `#core-registries`, from
// worker/jobs/src/lib/core.d/ (BH-8395).
//
// wrangler.jsonc's build.command runs it before every bundle, so a deploy
// always ships registries made from its own fragments. Node never reads the
// output: package.json "#core-registries" sends node to
// src/lib/core-registries.node.js.
//
//   node scripts/core-registries-build.mjs              write src/lib/core-registries.gen.js
//   node scripts/core-registries-build.mjs --out <path> write <path> instead
//   node scripts/core-registries-build.mjs --print      write to stdout
//   node scripts/core-registries-build.mjs --check      compose every fragment, render twice
//                                                       and compare, refuse a tracked or stale
//                                                       gen file; writes nothing
//
// Silent with exit 0 on success. On error: one `core-registries-build: <message>`
// line on stderr, exit 1, and no file written.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseCoreFragments, composeCoreRegistries, renderCoreRegistriesModule } from "../src/lib/core-registries.js";

async function main(argv) {
  const here = dirname(fileURLToPath(import.meta.url));
  const libDir = resolve(here, "../src/lib");
  const fragDir = join(libDir, "core.d");
  const gen = join(libDir, "core-registries.gen.js");
  let out = gen;
  let mode = "write";
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--print") mode = "print";
    else if (argv[i] === "--check") mode = "check";
    else if (argv[i] === "--out") {
      if (!argv[i + 1]) throw new Error("--out needs a path");
      out = resolve(argv[++i]);
    } else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (!existsSync(fragDir)) throw new Error(`no fragment directory: ${fragDir}`);
  const names = readdirSync(fragDir);
  // Compose under node first: a bad fragment fails here, before any write,
  // not inside the deployed worker.
  const frags = parseCoreFragments(names);
  const mods = await Promise.all(frags.map((f) => import(pathToFileURL(join(fragDir, f.file)).href)));
  composeCoreRegistries(frags.map((f, i) => [f.file, mods[i]]));
  const text = renderCoreRegistriesModule(names);

  if (mode === "check") {
    if (renderCoreRegistriesModule([...names].reverse()) !== text) throw new Error("the render is not deterministic");
    const ls = spawnSync("git", ["ls-files", "--error-unmatch", gen], { cwd: libDir, stdio: "ignore" });
    if (ls.status === 0) throw new Error(`${gen} is tracked in git; it is a git-ignored render (git rm --cached it)`);
    if (existsSync(gen) && readFileSync(gen, "utf8") !== text) throw new Error(`${gen} is stale; rerun node scripts/core-registries-build.mjs`);
    return;
  }
  if (mode === "print") { process.stdout.write(text); return; }
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
    process.stderr.write(`core-registries-build: ${String(e && e.message || e).split("\n")[0]}\n`);
    process.exit(1);
  }
}
