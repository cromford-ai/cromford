// D1 overload give-up streaks (BH-7541).
//
// A verdict route that gives up on "D1 DB is overloaded" answers 503 retryable
// (BH-6807), and bin/lib/jobs/req.sh retries that answer. So one give-up is a
// transient, not an error: Sentry issue CROMFORD-HARNESS-1G opened on single
// give-ups that the caller had already retried. recordGiveUp counts give-ups
// per route, and the route sends a Sentry event only on every Nth give-up of
// a streak (N = HARNESS_D1_GIVEUP_REPORT_AFTER, default 3). The Sentry SDK
// keeps one client per isolate, and its dedupe integration drops an event equal
// to the isolate's previous event, so a 6th give-up event right after the 3rd
// on the same isolate is dropped there; the open issue already shows the streak.
//
// A streak is give-ups on one route where each comes within
// HARNESS_D1_GIVEUP_WINDOW_S (default 900) of the one before. A success writes
// nothing (a write per successful read is new load on every request), so a
// quiet gap longer than the window starts the next give-up at 1.
//
// ONE statement per give-up, on the RAW binding (rawDb: one attempt, no
// retry): a retried counter write against an overloaded D1 adds the load the
// give-up exists to shed. If that write fails (overload, or the table is not
// applied yet), an in-isolate Map keeps the streak, so the decision still
// works. The DB row is the source of truth whenever it answers.
//
// N and the window are plain worker vars, not settings rows: they are read
// exactly when D1 is overloaded (same rule as the constants in d1-retry.js).
import { rawDb } from "./d1-retry.js";

export const DEFAULT_GIVEUP_REPORT_AFTER = 3;
export const DEFAULT_GIVEUP_WINDOW_S = 900;

const UPSERT = `INSERT INTO d1_overload_streaks (route, consecutive, first_at, last_at)
  VALUES (?1, 1, ?2, ?2)
  ON CONFLICT(route) DO UPDATE SET
    consecutive = CASE WHEN last_at >= ?3 THEN consecutive + 1 ELSE 1 END,
    first_at = CASE WHEN last_at >= ?3 THEN first_at ELSE ?2 END,
    last_at = ?2
  RETURNING consecutive`;
export const GIVEUP_UPSERT_SQL = UPSERT;

const local = new Map(); // route -> { n, last } (ms)

// For tests only: forget the in-isolate streaks.
export function resetGiveUpStreaks() {
  local.clear();
}

function positiveInt(v, dflt) {
  const n = parseInt(v, 10);
  return Number.isFinite(n) && n >= 1 ? n : dflt;
}

const isoOf = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// recordGiveUp(env, route, t) -> { consecutive, report, recorded }. Never throws.
export async function recordGiveUp(env, route, t) {
  const after = positiveInt(env && env.HARNESS_D1_GIVEUP_REPORT_AFTER, DEFAULT_GIVEUP_REPORT_AFTER);
  const windowS = positiveInt(env && env.HARNESS_D1_GIVEUP_WINDOW_S, DEFAULT_GIVEUP_WINDOW_S);
  const parsed = Date.parse(t);
  const nowMs = Number.isFinite(parsed) ? parsed : Date.now();
  const now = isoOf(nowMs);
  const since = isoOf(nowMs - windowS * 1000);
  let consecutive = null;
  try {
    const row = await rawDb(env.DB).prepare(UPSERT).bind(route, now, since).first();
    const n = row ? Number(row.consecutive) : NaN;
    if (Number.isFinite(n) && n >= 1) consecutive = n;
  } catch {
    // the fallback below keeps the streak
  }
  const recorded = consecutive !== null;
  if (!recorded) {
    const prev = local.get(route);
    consecutive = prev && prev.last >= nowMs - windowS * 1000 ? prev.n + 1 : 1;
  }
  local.set(route, { n: consecutive, last: nowMs });
  return { consecutive, report: consecutive % after === 0, recorded };
}
