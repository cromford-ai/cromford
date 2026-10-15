// staff-family — BH-5563 (BH-5556.6): THE class identity of a staff finding
// and the family key a noise suppression is proposed on.
//
// classSlug is the one rule for a class everywhere the learning loop reads
// one: the outcome row, staff_classes, precision by class, and the family. A
// value that is not a usable slug is `unclassified`, never dropped.
// familyFingerprint(agent, slug) is agent-core fingerprint() of
// {staff_family, class}: 64 hex, so it fits staff_suppressions.fingerprint, and
// it can never equal an item's own fingerprint by accident of shape. The claim
// route and the outcome route both call it from here.
import { fingerprint } from "../../../../agent-core/src/index.js";

const SLUG_RE = /^[a-z][a-z0-9-]{1,40}$/;

export function classSlug(raw) {
  if (typeof raw !== "string") return "unclassified";
  const s = raw.trim().toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 41);
  return SLUG_RE.test(s) ? s : "unclassified";
}

export function familyFingerprint(agent, slug) {
  return fingerprint({ staff_family: agent, class: slug });
}
