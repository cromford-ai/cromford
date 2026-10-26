// worker/jobs/src/lib/core-registries.node.js — the core.d/ registries for Node
// (node --test and every shell suite, BH-8395). package.json maps
// `#core-registries` here under the `default` condition. It reads core.d/ and
// imports each fragment at load time, so no core-registries.gen.js needs to
// exist in the tree. A bad fragment throws at import. wrangler never bundles
// this file: the `workerd` condition sends the bundle to the gen file.
import { readdirSync } from "node:fs";
import { parseCoreFragments, composeCoreRegistries } from "./core-registries.js";

const dir = new URL("./core.d/", import.meta.url);
const frags = parseCoreFragments(readdirSync(dir));
const mods = await Promise.all(frags.map((f) => import(new URL(f.file, dir))));
const C = composeCoreRegistries(frags.map((f, i) => [f.file, mods[i]]));

export const FRAGMENTS = frags.map((f) => f.file);
export const ADDED_COLUMNS = C.ADDED_COLUMNS;
export const ADDED_INDEXES = C.ADDED_INDEXES;
export const CREATED_TABLE_OVERRIDES = C.CREATED_TABLE_OVERRIDES;
