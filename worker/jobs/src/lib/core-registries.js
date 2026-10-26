// harness-jobs — the three schema registries core.js reads, composed from
// worker/jobs/src/lib/core.d/ (BH-8395).
//
// ADDED_COLUMNS, ADDED_INDEXES and CREATED_TABLE_OVERRIDES were three literal
// maps in core.js, and every build that added a column, an index or a statement
// edited the same lines of the same file. Now an entry is a fragment:
// core.d/<NNNN>-<name>.js (a frozen baseline) or core.d/<ticket-key>-<name>.js
// (a new entry). A fragment is a plain data module with no imports. It exports
// one or more of the three names, each an object of `<table>: [ ...items ]`,
// the same shape the literal maps had.
//
// Composition: file names sort with [...names].sort(), so every 0000-* baseline
// comes before every bh-* key. For each registry and table, the items of each
// fragment are concatenated in that order, and the first fragment that names a
// table fixes its key position. Two readers use this: core-registries.node.js
// imports the fragments when node loads the worker, and
// scripts/core-registries-build.mjs renders core-registries.gen.js for the
// wrangler bundle. Pure on purpose: no node: import, so it can sit in src/.

// Groups: 1 the four-digit baseline number or the ticket key, 2 the name.
export const CORE_FRAG_RE = /^(\d{4}|[a-z]+-\d+(?:[.-]\d+)?)-([a-z][a-z0-9-]*)\.js$/;

export const REGISTRIES = ["ADDED_COLUMNS", "ADDED_INDEXES", "CREATED_TABLE_OVERRIDES"];

// Table names are interpolated into SQL by ensureColumns, so they are idents.
const TABLE_RE = /^[a-z_][a-z0-9_]*$/;

// The fragments as [{ file, id }], sorted by file name. It throws on a name it
// would not read, rather than skip it: a skipped fragment is a column silently
// left out of the migration.
export function parseCoreFragments(names) {
  return [...names].sort().map((file, i) => {
    if (!CORE_FRAG_RE.test(file)) throw new Error(`not a <NNNN>-<name>.js or <ticket-key>-<name>.js fragment: ${file}`);
    return { file, id: `f${i}` };
  });
}

// One registry item, checked for its registry. Returns the key that must be
// unique per table: the column name, or the statement text.
function itemKey(reg, item, where) {
  if (reg === "ADDED_COLUMNS") {
    if (!Array.isArray(item) || item.length !== 2 || typeof item[0] !== "string" || typeof item[1] !== "string" || !item[0] || !item[1]) {
      throw new Error(`${where}: an ADDED_COLUMNS item must be a ["name", "TYPE"] pair: ${JSON.stringify(item)}`);
    }
    return item[0];
  }
  if (typeof item !== "string" || !item) throw new Error(`${where}: a ${reg} item must be a non-empty statement string: ${JSON.stringify(item)}`);
  return item;
}

// Append `items` to out[table], refusing an item already there.
function appendItems(reg, out, table, items, where) {
  if (!TABLE_RE.test(table)) throw new Error(`${where}: not a table name: ${table}`);
  if (!Array.isArray(items)) throw new Error(`${where}: ${reg}.${table} must be an array`);
  const list = out[table] || (out[table] = []);
  const seen = new Set(list.map((it) => itemKey(reg, it, where)));
  for (const item of items) {
    const key = itemKey(reg, item, where);
    if (seen.has(key)) throw new Error(`${where}: ${reg}.${table} names ${JSON.stringify(key)} twice`);
    seen.add(key);
    list.push(item);
  }
}

// entries: [file, module] pairs, in any order. Returns the three registries.
export function composeCoreRegistries(entries) {
  const byFile = new Map(entries);
  const out = Object.fromEntries(REGISTRIES.map((r) => [r, {}]));
  for (const { file } of parseCoreFragments([...byFile.keys()])) {
    const mod = byFile.get(file);
    const names = Object.keys(mod);
    const unknown = names.filter((n) => !REGISTRIES.includes(n));
    if (unknown.length) throw new Error(`core.d/${file}: unknown export ${unknown.join(", ")} (allowed: ${REGISTRIES.join(", ")})`);
    if (!names.length) throw new Error(`core.d/${file}: exports none of ${REGISTRIES.join(", ")}`);
    for (const reg of names) {
      const map = mod[reg];
      if (!map || typeof map !== "object" || Array.isArray(map)) throw new Error(`core.d/${file}: ${reg} must be an object of table: [items]`);
      for (const [table, items] of Object.entries(map)) appendItems(reg, out[reg], table, items, `core.d/${file}`);
    }
  }
  return out;
}

// base with extra's items concatenated per table, by the same rule. A table
// extra does not name keeps base's array object, so an identity check on an
// override (test/created-tables.bh-4987.test.js T3) holds. base is not mutated.
export function mergeTableLists(base, extra) {
  const out = { ...base };
  for (const [table, items] of Object.entries(extra)) {
    const merged = { [table]: [...(base[table] || [])] };
    appendItems("CREATED_TABLE_OVERRIDES", merged, table, items, "core.d");
    out[table] = merged[table];
  }
  return out;
}

// The exact text of src/lib/core-registries.gen.js for these fragment names.
export function renderCoreRegistriesModule(names) {
  const frags = parseCoreFragments(names);
  return [
    "// GENERATED by worker/jobs/scripts/core-registries-build.mjs from worker/jobs/src/lib/core.d/ (BH-8395).",
    "// Git-ignored. wrangler.jsonc build.command renders it before every bundle; Node reads core-registries.node.js instead.",
    'import { composeCoreRegistries } from "./core-registries.js";',
    ...frags.map((f) => `import * as ${f.id} from "./core.d/${f.file}";`),
    "",
    `export const FRAGMENTS = [${frags.map((f) => JSON.stringify(f.file)).join(", ")}];`,
    "",
    "const C = composeCoreRegistries([",
    ...frags.map((f) => `  [${JSON.stringify(f.file)}, ${f.id}],`),
    "]);",
    "",
    ...REGISTRIES.map((r) => `export const ${r} = C.${r};`),
    "",
  ].join("\n");
}
