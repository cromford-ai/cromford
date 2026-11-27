// BH-10218: the change signal of the repo-metadata memo (bin/lib/repo-meta.sh
// via bin/lib/repo-change-mark.sh). A `repository` delivery wakes only for the
// actions that change what the memo holds: a new default branch, a new name, a
// new owner. Keyed on the numeric repository id, never on a name. No lane
// consumes kind `repo` from the wake loop; it is read from the read-only wake
// mirror (bin/lib/pr-snapshot-wakes.sh).
//
// Its own module, not a case in wakeOf (src/lib/core.js is a registry file,
// catalog/list-files.tsv). wakeOf returns null for `repository`, so
// githubWakeOf tries it first and this mapping second. Pure; never throws.
import { wakeOf } from "./core.js";

const obj = (v) => (v && typeof v === "object" ? v : {});

export function wakeOfRepository(event, p) {
  if (event !== "repository") return null;
  const pay = obj(p);
  const action = String(pay.action || "");
  const edited = action === "edited" && Boolean(obj(pay.changes).default_branch);
  if (!edited && action !== "renamed" && action !== "transferred") return null;
  const id = String(obj(pay.repository).id ?? "");
  if (!/^[1-9][0-9]{0,15}$/.test(id)) return null;
  return { kind: "repo", key: id };
}

// The one mapping the GitHub receiver calls: wakeOf, then the kinds that live
// in their own module.
export function githubWakeOf(event, p) {
  return wakeOf(event, p) || wakeOfRepository(event, p);
}
