// worker/jobs/test/lib/routes.node.js — the gated route table for Node
// (node --test and every shell suite, BH-4607). package.json maps `#routes`
// here under the `default` condition. It reads test/route-table.d/ and imports
// each gated family at load time, so no src/routes.gen.js needs to exist in
// the tree. A stray fragment or a missing module throws at import.
import { readdirSync } from "node:fs";
import { gatedFamilies } from "../../src/lib/route-families.js";

const dir = new URL("../route-table.d/", import.meta.url);
const fams = gatedFamilies(readdirSync(dir));
const mods = await Promise.all(fams.map((f) => import(new URL(`../../src/routes/${f}.js`, import.meta.url))));

export const FAMILIES = fams;
export const ROUTES = mods.flatMap((m) => m.routes);
