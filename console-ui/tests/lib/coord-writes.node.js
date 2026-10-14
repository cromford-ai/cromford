// console-ui/tests/lib/coord-writes.node.js — the coord write fragments for
// Node (node --test and every shell suite, BH-6487). package.json maps
// `#coord-writes` here under the `default` condition. It reads
// functions/_lib/coord-writes.d/ at import time, so no coord-writes.gen.js
// needs to exist in the tree. A stray name or a duplicate row throws.
import { readdirSync } from 'node:fs';
import { checkWrites, fragmentNames } from '../../functions/_lib/coord-writes-compose.js';

const dir = new URL('../../functions/_lib/coord-writes.d/', import.meta.url);
const mods = await Promise.all(fragmentNames(readdirSync(dir)).map((f) => import(new URL(f, dir))));

export const FRAGMENT_WRITES = checkWrites(mods.flatMap((m) => m.default));
