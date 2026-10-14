// The shared predicates of the coord proxy's write table (BH-6487).
//
// THE WRITE SURFACE (BH-2405). Every non-GET the proxy admits is one row, and
// the row says exactly which body fields and which query fields travel to
// the worker. Nothing else does: not an unknown field, not the browser's
// `actor`, not a query string on a body write. `actor` is never in a list; it
// is stamped. `ok(key, value)` narrows a field's type where the worker would
// otherwise coerce it; `build(sent, env, actor)` replaces the pick for a row whose
// body is rebuilt from the worker's own state. `needsReason` refuses the write
// with a 400 unless `reason` is a non-blank string.
//
// WHERE A ROW LIVES. The rows that existed at BH-6487 stay in WRITES in
// functions/api/coord/[[path]].js. A NEW row is a new file,
// functions/_lib/coord-writes.d/<NNNN>-<slug>.js, where <NNNN> is the ticket
// number: `export default [ <rows> ];`, importing only from this file. The
// proxy matches WRITES first, then the fragments in name order. Two rows with
// the same method and the same string path refuse to load
// (coord-writes-compose.js checkWrites). Node composes the directory through
// tests/lib/coord-writes.node.js; the Pages bundle imports
// coord-writes.gen.js, which scripts/coord-writes-build.mjs renders and git
// ignores (package.json "#coord-writes").
export const isStr = (_k, v) => typeof v === 'string';
export const isScalar = (k, v) => typeof v === 'string' || (k !== 'action' && typeof v === 'number' && Number.isFinite(v));

export const jsonError = (status, error) =>
  new Response(JSON.stringify({ error }), { status, headers: { 'content-type': 'application/json' } });
