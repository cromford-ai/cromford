// The harness sha a job start record stores (BH-7305): a lane_runs claim, a
// build_queue claim-machine stamp and a lane_machines start record. Only a git
// short or full sha (7-40 hex, trimmed, lower-cased) is stored; anything else
// is null, and the request answers as it does without the field.
const SHA_RE = /^[0-9a-f]{7,40}$/;
export function harnessShaOf(v) {
  if (typeof v !== "string") return null;
  const s = v.trim().toLowerCase();
  return SHA_RE.test(s) ? s : null;
}
