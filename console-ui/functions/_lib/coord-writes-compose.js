// Composes the coord proxy's write table from functions/_lib/coord-writes.d/
// (BH-6487). Pure: no fs, so the Pages bundle can import checkWrites.

const FRAGMENT_RE = /^([0-9]{4,6})-[a-z0-9][a-z0-9-]*\.js$/;
const METHODS = ['PUT', 'POST', 'PATCH', 'DELETE'];

// fragmentNames(names) — the fragment files in load order: the numeric
// prefix, then the name in byte order. Any other entry throws.
export function fragmentNames(names) {
  for (const n of names) {
    if (!FRAGMENT_RE.test(n)) throw new Error(`coord-writes.d/${n} is not a fragment name (NNNN-<slug>.js)`);
  }
  const num = (n) => Number(FRAGMENT_RE.exec(n)[1]);
  return [...names].sort((a, b) => num(a) - num(b) || (a < b ? -1 : a > b ? 1 : 0));
}

// renderWritesModule(names) — the text of coord-writes.gen.js.
export function renderWritesModule(names) {
  const files = fragmentNames(names);
  return [
    '// GENERATED from functions/_lib/coord-writes.d/ by scripts/coord-writes-build.mjs. Do not edit; add a fragment.',
    "import { checkWrites } from './coord-writes-compose.js';",
    ...files.map((f, i) => `import f${i} from './coord-writes.d/${f}';`),
    `export const FRAGMENT_WRITES = checkWrites([${files.map((_f, i) => `...f${i}`).join(', ')}]);`,
    ''
  ].join('\n');
}

// checkWrites(rows) — rows, unchanged, or a throw naming the first bad row.
export function checkWrites(rows) {
  const seen = new Set();
  for (const w of rows) {
    if (!w || typeof w !== 'object' || Array.isArray(w)) throw new Error(`write row ${JSON.stringify(w)} is not an object`);
    const name = `${w.method} ${typeof w.path === 'function' ? '<fn>' : w.path}`;
    if (!METHODS.includes(w.method)) throw new Error(`write row ${name}: method must be one of ${METHODS.join(' ')}`);
    if (typeof w.path !== 'function' && (typeof w.path !== 'string' || !w.path)) throw new Error(`write row ${name}: path must be a non-empty string or a function`);
    if (w.body !== null && !Array.isArray(w.body)) throw new Error(`write row ${name}: body must be an array or null`);
    if (typeof w.path === 'string') {
      if (seen.has(name)) throw new Error(`${name} is a write row twice`);
      seen.add(name);
    }
  }
  return rows;
}
