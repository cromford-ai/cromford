// coord-writes-build.mjs — renders functions/_lib/coord-writes.gen.js, the
// coord proxy's fragment write rows, from functions/_lib/coord-writes.d/
// (BH-6487).
//
// `npm run build` runs it before vite, and bin/lib/console-preview.sh
// (cpv_coord_writes) runs it in the archive-only deploy trees, so a Pages
// deploy always bundles a table made from its own fragments. Node never reads
// the output: package.json "#coord-writes" sends node to
// tests/lib/coord-writes.node.js.
//
//   node scripts/coord-writes-build.mjs              write functions/_lib/coord-writes.gen.js
//   node scripts/coord-writes-build.mjs --out <path> write <path> instead
//   node scripts/coord-writes-build.mjs --print      write to stdout
//
// Silent with exit 0 on success. On error: one `coord-writes-build: <message>`
// line on stderr, exit 1, and no file written.
import { existsSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { checkWrites, fragmentNames, renderWritesModule } from '../functions/_lib/coord-writes-compose.js';

async function main(argv) {
  const here = dirname(fileURLToPath(import.meta.url));
  const libDir = resolve(here, '../functions/_lib');
  const fragDir = join(libDir, 'coord-writes.d');
  let out = join(libDir, 'coord-writes.gen.js');
  let print = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--print') print = true;
    else if (argv[i] === '--out') {
      if (!argv[i + 1]) throw new Error('--out needs a path');
      out = resolve(argv[++i]);
    } else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (!existsSync(fragDir)) throw new Error(`no fragment directory: ${fragDir}`);
  const names = readdirSync(fragDir);
  const text = renderWritesModule(names);
  // Load every fragment once, so a bad row fails the render and not the deploy.
  const files = fragmentNames(names);
  const mods = await Promise.all(files.map((f) => import(pathToFileURL(join(fragDir, f)).href)));
  checkWrites(mods.flatMap((m, i) => {
    if (!Array.isArray(m.default)) throw new Error(`coord-writes.d/${files[i]} must export default an array of write rows`);
    return m.default;
  }));
  if (print) { process.stdout.write(text); return; }
  // The same bytes: no write, so a re-render does not touch the mtime.
  if (existsSync(out) && readFileSync(out, 'utf8') === text) return;
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
    process.stderr.write(`coord-writes-build: ${e.message}\n`);
    process.exit(1);
  }
}
