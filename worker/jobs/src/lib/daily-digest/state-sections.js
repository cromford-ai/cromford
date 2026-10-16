// daily-digest state sections — BH-3705 (BH-3688 slice 3). Read-only D1.
//
// In-window reads, [win.from, win.to):
//   tripwires            ledgers build-tripwire (created), child_plan_tripwire
//                        fired (created), review_block_fp at >= opts.trip (updated),
//                        deploy_rollback (created; bin/deploy-rollback-board.sh, BH-4915)
//   spotcheck_candidates lead_review_requests done + MERGE (updated)
//   self_heals           ledgers self_heal (created; a re-put keeps created_at,
//                        so one event counts once), key <source>:<fingerprint>
// Current state at request time:
//   holds                ledgers ticket_hold held, pr_state BLOCKED_HUMAN,
//                        triage_state last_decision hold:waiting-on-human
//   human_verdict_prs    pr_state BLOCKED_HUMAN
//   model_watch          model_watch status='suggested'
//   factory              settings switch.factory-stop, pause_flags all-off,
//                        live fleet pauses
//   past_sla             ledgers stuck_work_snapshot/latest (bin/stuck-work.sh);
//                        no row or bad detail is ok:false, > 30 min old is stale
//   pr_health            ledgers pr_health, one row per project written by
//                        bin/pr-owner-sweep.sh (BH-3936); latest per project,
//                        a malformed detail is skipped and counted
//
// Each section runs in its own try: a failed read is {ok:false,error} for that
// section only, never an empty list.
import { capList } from "./shape.js";
import { nowIso } from "../http.js";
import { readFleetFlag } from "../harness-flags.js";
import { sqlIdent } from "../sql-ident.js";

const SNAPSHOT_STALE_MS = 30 * 60 * 1000;

async function sect(fn) {
  try {
    return { ok: true, ...(await fn()) };
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
}

async function rowsOf(stmt) {
  const res = await stmt.all();
  if (!Array.isArray(res?.results)) throw new Error("D1 read returned no results array");
  return res.results;
}

// "<project> <KEY>" for the tripwire ledgers, "<project>#<n>[#<fp>]" for
// review_block_fp and ticket_hold. No separator: project null, key kept whole.
function splitAt(key, sep) {
  const i = key.indexOf(sep);
  return i < 0 ? { project: null, rest: key } : { project: key.slice(0, i), rest: key.slice(i + 1) };
}
function splitKey(kind, key) {
  if (kind === "review_block_fp") {
    const { project, rest } = splitAt(key, "#");
    return { project, key: project === null ? rest : rest.split("#")[0] };
  }
  const { project, rest } = splitAt(key, " ");
  return { project, key: rest };
}

const repoName = (repo) => String(repo).split("/").pop();
const byFields = (...fs) => (a, b) => {
  for (const f of fs) {
    const x = String(a[f] ?? ""), y = String(b[f] ?? "");
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
};

function parseSwitch(v) {
  const s = String(v).trim().toLowerCase();
  return s === "1" || s === "true";
}

// A pr_health detail in the exact shape the sweep writes, or null.
const AGE_BUCKETS = ["lt1d", "1to3d", "3to7d", "gt7d"];
function prHealthDetail(raw) {
  let d;
  try { d = JSON.parse(raw); } catch { return null; }
  if (!d || typeof d !== "object" || typeof d.day !== "string") return null;
  const counts = ["open", "ownerless", "approved_not_merged", "blocked_ci_only"];
  if (!counts.every((k) => Number.isInteger(d[k]))) return null;
  if (!d.age || typeof d.age !== "object" || !AGE_BUCKETS.every((k) => Number.isInteger(d.age[k]))) return null;
  return {
    day: d.day,
    open: d.open,
    age: Object.fromEntries(AGE_BUCKETS.map((k) => [k, d.age[k]])),
    ownerless: d.ownerless,
    approved_not_merged: d.approved_not_merged,
    blocked_ci_only: d.blocked_ci_only,
  };
}

// BH-4953: the `pr_state` view is MAX(id) per PR over every row, and gate
// facts (state='gate') are rows too, so the newest gate fact would hide a
// BLOCKED_HUMAN PR. This is the view's rule with gate rows left out.
// BH-5667: merge-queue stage rows (state='queue') are left out the same way.
export const PR_STATE_NO_GATE = `(SELECT e.* FROM pr_state_events e WHERE e.id =
  (SELECT MAX(id) FROM pr_state_events WHERE repo=e.repo AND number=e.number AND state NOT IN ('gate','queue')))`;

export async function readStateSections(db, win, opts) {
  const { from, to } = win;
  const now = nowIso();

  const tripwires = sect(async () => {
    // sql-ident-ok: col passes sqlIdent; where is a literal predicate from the three calls below
    const sql = (where, col) => sqlIdent(col) && db.prepare(
      `SELECT kind, key, ${col} AS at FROM ledgers WHERE ${where} AND ${col} >= ? AND ${col} < ?`);
    const got = [
      ...(await rowsOf(sql("kind='build-tripwire'", "created_at").bind(from, to))),
      ...(await rowsOf(sql("kind='child_plan_tripwire' AND status='fired'", "created_at").bind(from, to))),
      ...(await rowsOf(sql("kind='deploy_rollback'", "created_at").bind(from, to))),
      ...(await rowsOf(db.prepare(
        `SELECT kind, key, updated_at AS at FROM ledgers
          WHERE kind='review_block_fp' AND CAST(status AS INTEGER) >= ? AND updated_at >= ? AND updated_at < ?`,
      ).bind(opts.trip, from, to))),
    ];
    const rows = got
      .map((r) => ({ kind: r.kind, ...splitKey(r.kind, r.key), at: r.at }))
      .sort(byFields("at", "kind", "key"));
    return { n: rows.length, ...capList(rows, opts.limit) };
  });

  const holds = sect(async () => {
    const held = await rowsOf(db.prepare(
      `SELECT key, updated_at FROM ledgers WHERE kind='ticket_hold' AND status='held'`));
    // sql-ident-ok: PR_STATE_NO_GATE is a module constant subquery
    const prs = await rowsOf(db.prepare(
      `SELECT repo, number, since FROM ${PR_STATE_NO_GATE} WHERE state='BLOCKED_HUMAN'`));
    const waiting = await rowsOf(db.prepare(
      `SELECT project, ticket_key, last_decision_at FROM triage_state
        WHERE last_decision LIKE '%hold:waiting-on-human%'`));
    const rows = [
      ...held.map((r) => {
        const { project, rest } = splitAt(r.key, "#");
        return { source: "ticket_hold", project, key: `#${rest}`, since: r.updated_at };
      }),
      ...prs.map((r) => ({ source: "BLOCKED_HUMAN", project: repoName(r.repo), key: `#${r.number}`, since: r.since })),
      ...waiting.map((r) => ({ source: "waiting-on-human", project: r.project, key: r.ticket_key, since: r.last_decision_at })),
    ].sort(byFields("since", "source", "project", "key"));
    return {
      n: rows.length,
      basis: "D1 holds only (console holds, BLOCKED_HUMAN PRs, triage-seen waiting-on-human)",
      ...capList(rows, opts.limit),
    };
  });

  const human_verdict_prs = sect(async () => {
    // sql-ident-ok: PR_STATE_NO_GATE is a module constant subquery
    const got = await rowsOf(db.prepare(
      `SELECT repo, number, COALESCE(NULLIF(reason,''), state) AS reason, since FROM ${PR_STATE_NO_GATE}
        WHERE state IN ('BLOCKED_HUMAN','NEEDS_HUMAN_VERDICT') ORDER BY since, repo, number`));
    const rows = got.map((r) => ({ project: repoName(r.repo), repo: r.repo, number: r.number, reason: r.reason, since: r.since }));
    return { n: rows.length, ...capList(rows, opts.limit) };
  });

  const model_watch = sect(async () => {
    const rows = await rowsOf(db.prepare(
      `SELECT vendor, model_id, COALESCE(suggestion,'') AS suggestion FROM model_watch
        WHERE status='suggested' ORDER BY first_seen DESC, vendor, model_id`));
    return capList(rows.map((r) => ({ vendor: r.vendor, model_id: r.model_id, suggestion: r.suggestion })), opts.limit);
  });

  const spotcheck_candidates = sect(async () => {
    const got = await rowsOf(db.prepare(
      `SELECT repo, pr, head_sha FROM lead_review_requests
        WHERE status='done' AND verdict='MERGE' AND updated_at >= ? AND updated_at < ?
        ORDER BY updated_at, repo, pr`,
    ).bind(from, to));
    const rows = got.map((r) => ({ repo: r.repo, pr: r.pr, head_sha: r.head_sha, project: repoName(r.repo) }));
    return capList(rows, opts.limit);
  });

  const factory = sect(async () => {
    const [stop] = await rowsOf(db.prepare(
      `SELECT value, actor, updated_at FROM settings WHERE key='switch.factory-stop'`));
    const off = await readFleetFlag({ DB: db }, "all-off");
    // At most four rows: `what` is CHECKed to four values and pauses_live is
    // unique on (scope, what) while ended_at IS NULL.
    const fleet = await rowsOf(db.prepare(
      `SELECT what, expires_at, actor FROM pauses
        WHERE scope='fleet' AND ended_at IS NULL AND expires_at > ? ORDER BY expires_at, what`,
    ).bind(now));
    return {
      factory_stop: stop
        ? { set: parseSwitch(stop.value), value: stop.value, actor: stop.actor ?? null, updated_at: stop.updated_at }
        : { set: false, value: null, actor: null, updated_at: null },
      all_off: off && Number(off.active) === 1
        ? { set: true, actor: off.actor ?? null, since: off.updated_at }
        : { set: false, actor: null, since: null },
      fleet_pauses: fleet.map((r) => ({ what: r.what, expires_at: r.expires_at, actor: r.actor })),
    };
  });

  // The lane runs every 5 min; a snapshot older than this is the digest's
  // "stale", a display rule here, not a business threshold.
  const past_sla = sect(async () => {
    const [r] = await rowsOf(db.prepare(
      `SELECT detail, updated_at FROM ledgers WHERE kind='stuck_work_snapshot' AND key='latest'`));
    if (!r) throw new Error("no stuck-work snapshot");
    const d = JSON.parse(r.detail);
    if (!Number.isInteger(d?.total) || !d.by_state || typeof d.by_state !== "object") {
      throw new Error("stuck-work snapshot unreadable");
    }
    return {
      total: d.total,
      by_state: d.by_state,
      as_of: r.updated_at,
      stale: Date.parse(now) - Date.parse(r.updated_at) > SNAPSHOT_STALE_MS,
    };
  });

  // BH-4724: the notices bin/lib/self-heal.sh writes. by_source is in sorted
  // source order; a key with no ":" counts in n with source null.
  const self_heals = sect(async () => {
    const got = await rowsOf(db.prepare(
      `SELECT key, created_at FROM ledgers WHERE kind='self_heal' AND created_at >= ? AND created_at < ?`,
    ).bind(from, to));
    const rows = got
      .map((r) => {
        const { project, rest } = splitAt(r.key, ":");
        return { source: project, key: rest, at: r.created_at };
      })
      .sort(byFields("at", "source", "key"));
    const by_source = {};
    for (const s of [...new Set(rows.map((r) => r.source).filter((s) => s !== null))].sort()) {
      by_source[s] = rows.filter((r) => r.source === s).length;
    }
    return { n: rows.length, by_source, ...capList(rows, opts.limit) };
  });

  const pr_health = sect(async () => {
    const got = await rowsOf(db.prepare(
      `SELECT key, detail, updated_at FROM ledgers WHERE kind='pr_health' ORDER BY updated_at DESC`));
    const seen = new Set();
    const rows = [];
    let skipped = 0;
    for (const r of got) {
      if (seen.has(r.key)) continue;
      seen.add(r.key);
      const d = prHealthDetail(r.detail);
      if (!d) { skipped++; continue; }
      rows.push({ project: r.key, ...d, as_of: r.updated_at });
    }
    rows.sort(byFields("project"));
    return { rows, skipped };
  });

  return {
    tripwires: await tripwires,
    self_heals: await self_heals,
    holds: await holds,
    human_verdict_prs: await human_verdict_prs,
    model_watch: await model_watch,
    spotcheck_candidates: await spotcheck_candidates,
    factory: await factory,
    pr_health: await pr_health,
    past_sla: await past_sla,
  };
}
