// hosted-board-members routes — a seam for a later wave of BH-7913 (BH-8918 made it
// empty). The hosted Board API itself is ./hosted-board.js. This module mounts
// no route: it has no test/route-table.d fragment, and an empty `routes` list
// is a seam (test/route-registry.bh-4607.test.js N5). A later wave fills it and
// adds its fragment in the same PR.
export const routes = [];
