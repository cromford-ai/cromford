// worker/jobs/src/lib/retention-rules.node.js — the retention.d/ rules for Node
// (node --test and every shell suite, BH-8398.0). package.json maps
// `#retention-rules` here under the `default` condition. It reads
// src/routes/retention.d/ and imports each fragment at load time, so no
// retention-rules.gen.js needs to exist in the tree. A bad fragment throws at
// import. wrangler never bundles this file: the `workerd` condition sends the
// bundle to the gen file.
import { readdirSync } from "node:fs";
import { checkRules, fragmentNames, fragmentRules } from "./retention-rules.js";

const dir = new URL("../routes/retention.d/", import.meta.url);
const files = fragmentNames(readdirSync(dir));
const mods = await Promise.all(files.map((f) => import(new URL(f, dir))));

export const FRAGMENTS = files;
export const RULES = checkRules(files.flatMap((f, i) => fragmentRules(f, mods[i])));
