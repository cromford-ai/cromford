// The client approval gate (project-3, 2026-11-12). A repo whose settings row
// lead_authority_mode.<owner>.<name> is `client` withholds every PR that
// touches one of its lead_protected_paths globs until a --source human MERGE
// stands on the head (bin/lib/lead-authority.sh, THE CLIENT MODE). Any box
// holds the bearer, so without this a box could switch the gate off. Two
// writes LOOSEN it and need the human verdict token:
//   1. PUT /api/settings that moves lead_authority_mode[.x] away from client;
//   2. PUT /api/lead-protected-paths op=remove on a repo in client mode.
// Tightening (setting client, adding a glob) stays a bearer write.

const MODE_RE = /^lead_authority_mode(\.|$)/;
const norm = (v) => (v == null ? "" : String(v).trim().toLowerCase());

// clientModeGlobalRefusal(key, value) -> null, or the error for a 400. client
// is a per-repo value only (lead_authority_mode.<owner>.<name>): on the global
// key it would hold every fleet repo's protected paths.
export function clientModeGlobalRefusal(key, value) {
  if (key !== "lead_authority_mode" || norm(value) !== "client") return null;
  return "lead_authority_mode=client is refused: client is a per-repo value only; set lead_authority_mode.<owner>.<name>";
}

// clientModeLoosening(key, from, to) -> true when the write leaves client.
export function clientModeLoosening(key, from, to) {
  if (typeof key !== "string" || !MODE_RE.test(key)) return false;
  return norm(from) === "client" && norm(to) !== "client";
}

// modeKeyOfRepo("Owner/Name") -> "lead_authority_mode.owner.name"
export function modeKeyOfRepo(repo) {
  return "lead_authority_mode." + String(repo).toLowerCase().replace("/", ".");
}

// repoInClientMode(env, repo) -> true when the repo's own mode row reads client.
// Only the per-repo key counts, the same rule as bin/lib/lead-authority.sh
// (_la_mode holds on a global client row, and the PUT refuses one).
export async function repoInClientMode(env, repo) {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(modeKeyOfRepo(repo)).first();
  return norm(r?.value) === "client";
}
