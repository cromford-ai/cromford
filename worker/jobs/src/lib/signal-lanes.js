// The signal key lane gate (BH-9800). The settings row signal_keys.read_lanes
// lists the lane-run lanes whose runs may read a signal key
// (POST /api/signal-keys/read). Such a lane gets the web-task rules
// (routes/web-vault.js): its claim mints a run token, and its enqueue needs the
// operator token, so a bearer holder cannot make a run of any project and
// claim it to read that project's key. The seed is empty: no lane changes
// until an operator lists one. web-task itself is always a run-token lane.
import { json } from "./http.js";
import { laneName } from "./core.js";
import { adminOk, webTaskEnqueueRefused, WEB_TASK_LANE } from "../routes/web-vault.js";

export const READ_LANES_KEY = "signal_keys.read_lanes";
// The settings PRIMARY KEY, one row (the lane-runs.js knob read shape).
const READ_LANES_SQL = "SELECT value FROM settings WHERE key=?1";

// The lanes of the row's value: trimmed, lower-cased, lane names only.
export function signalReadLanes(value) {
  return String(value === undefined || value === null ? "" : value).split(",")
    .map((s) => laneName(s.trim().toLowerCase())).filter(Boolean);
}

// The listed lanes. A D1 throw propagates.
export async function readLanes(env) {
  const row = await env.DB.prepare(READ_LANES_SQL).bind(READ_LANES_KEY).first();
  return signalReadLanes(row && row.value);
}

// True when a claim of `lane` mints a run token: web-task, or a listed lane.
// The row is read only for another lane. A failed read is false: the claim
// stands with no token, and that run's reads are refused bad_token.
export async function runTokenLane(env, lane) {
  if (lane === WEB_TASK_LANE) return true;
  try {
    return (await readLanes(env)).includes(lane);
  } catch {
    return false;
  }
}

// A 403 Response, or null. The web-task rule first; then a listed lane without
// the operator token. A failed read throws to the route's d1Guarded (503).
export async function operatorLaneEnqueueRefused(req, env, lane) {
  const refused = webTaskEnqueueRefused(req, env, lane);
  if (refused) return refused;
  if (lane === WEB_TASK_LANE || adminOk(req, env)) return null;
  if (!(await readLanes(env)).includes(lane)) return null;
  return json(403, { error: `lane ${lane} reads signal keys and is enqueued with the operator token only (x-web-vault-admin-token)` });
}
