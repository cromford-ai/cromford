// Owner: BH-7940.4 (marker lint). BH-7940.0 ships the seam.
// prompt-markers — the markers a saved prompt body must keep, per kind, read
// from the bundled catalog/prompt-markers.json. saveVersion refuses a body
// that lacks one (422 missing_marker). The lists are empty until BH-7940.4
// fills them, so today every known kind answers [].

import CATALOG from "../../../../catalog/prompt-markers.json" with { type: "json" };

// -> the catalog markers of `kind` that `body` does not contain. A kind the
// catalog does not name throws: a typo must not pass the lint.
export function missingMarkers(kind, body) {
  if (!Object.prototype.hasOwnProperty.call(CATALOG, kind)) throw new Error(`unknown prompt kind: ${kind}`);
  return CATALOG[kind].filter((m) => !String(body).includes(m));
}
