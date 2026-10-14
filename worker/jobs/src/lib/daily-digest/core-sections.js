// daily-digest core sections — BH-3704 (BH-3688 slice 2): throughput, spend
// and autonomy for one UTC day. Read-only.
//
// Each section reads inside its own try, so one failed read is {ok:false,error}
// for that section and never a zero in another. Every window is
// `col >= win.from AND col < win.to`. Every list is fetched limit+1 and capped
// with capList, and its n is a separate COUNT(*), never the capped length.
import { capList } from "./shape.js";
import { isHumanActor, filingToMerge } from "./core-pure.js";
import { humanProven } from "../../routes/verdicts.js";

// One day's merges are read whole; a day past this is an error, not a
// silently short count.
const MERGE_MAX = 2000;
const TOP_TICKETS = 3;
// One day's signed human verdict rows are read up to this; past it the count
// is of the rows read, and the log says so.
const HUMAN_ROWS_MAX = 5000;

// Every query below is a literal: values and LIMITs are bound, never
// interpolated. The merged-on-day predicate is
// kind='merge' AND status='merged' AND created_at>=?1 AND created_at<?2.

// Human-intervention sources: table -> its read, each a literal. verdicts and
// ticket_hold are read separately (human by construction, no actor filter).
// The key order is the fixture's.
const ACTOR_TABLES = [
  ["config_changes", "SELECT actor, COUNT(*) AS c FROM config_changes WHERE at>=?1 AND at<?2 GROUP BY actor"],
  ["model_route_changes", "SELECT actor, COUNT(*) AS c FROM model_route_changes WHERE at>=?1 AND at<?2 GROUP BY actor"],
  ["routing_changes", "SELECT actor, COUNT(*) AS c FROM routing_changes WHERE at>=?1 AND at<?2 GROUP BY actor"],
  ["cost_cap_changes", "SELECT actor, COUNT(*) AS c FROM cost_cap_changes WHERE at>=?1 AND at<?2 GROUP BY actor"],
  ["route_rule_changes", "SELECT actor, COUNT(*) AS c FROM route_rule_changes WHERE at>=?1 AND at<?2 GROUP BY actor"],
  ["flaky_quarantine_changes", "SELECT actor, COUNT(*) AS c FROM flaky_quarantine_changes WHERE at>=?1 AND at<?2 GROUP BY actor"],
  ["alert_actions", "SELECT actor, COUNT(*) AS c FROM alert_actions WHERE at>=?1 AND at<?2 GROUP BY actor"],
  ["stage_events", "SELECT actor, COUNT(*) AS c FROM stage_events WHERE created_at>=?1 AND created_at<?2 GROUP BY actor"],
  ["pauses", "SELECT actor, COUNT(*) AS c FROM pauses WHERE created_at>=?1 AND created_at<?2 GROUP BY actor"],
];

const BATCH_BASIS =
  "pr_state_events reason queue-ejected* (needs pr-state-rows) + ledgers batch_member red|abandoned (needs no-twin-ledgers)";

const all = async (db, sql, ...binds) => (await db.prepare(sql).bind(...binds).all()).results || [];
const count = async (db, sql, ...binds) => Number((await db.prepare(sql).bind(...binds).first("n")) ?? 0);

async function section(fn) {
  try {
    return await fn();
  } catch (err) {
    return { ok: false, error: String(err?.message || err) };
  }
}

async function readThroughput(db, win) {
  const merges = await all(db,
    `SELECT key, created_at FROM ledgers WHERE kind='merge' AND status='merged' AND created_at>=?1 AND created_at<?2 ORDER BY created_at LIMIT ?3`,
    win.from, win.to, MERGE_MAX + 1);
  if (merges.length > MERGE_MAX) throw new Error(`more than ${MERGE_MAX} merges in one day`);
  const artifacts = await all(db,
    `SELECT a.artifact_ref AS artifact_ref, a.job_id AS job_id, j.kind AS job_kind,
            j.project AS project, j.ticket_id AS ticket_id, j.created_at AS job_created_at
       FROM job_artifacts a JOIN jobs j ON j.id=a.job_id
      WHERE a.artifact_kind='pr_url' AND a.artifact_ref IN (SELECT key FROM ledgers
                                                  WHERE kind='merge' AND status='merged' AND created_at>=?1 AND created_at<?2)`,
    win.from, win.to);
  // BH-6727: the merged set first, then the tickets it names, then their jobs.
  // CROSS JOIN fixes the order (SQLite never reorders it): the merge window is
  // read first, through idx_ledgers_kind_status_created, and each merge finds
  // its artifact by (artifact_kind, artifact_ref).
  // The earlier correlated EXISTS re-ran the merge -> artifact -> job lookup
  // for EVERY jobs row (1,293,710 rows read a call on 49k jobs). Same rows out:
  // each (project, ticket_id) with a merged PR in the window, and the earliest
  // non-null issue_created_at among that ticket's jobs.
  const jobs = await all(db,
    `WITH t AS MATERIALIZED (
       SELECT DISTINCT j2.project AS project, j2.ticket_id AS ticket_id
         FROM ledgers l
         CROSS JOIN job_artifacts a ON a.artifact_kind='pr_url' AND a.artifact_ref=l.key
         JOIN jobs j2 ON j2.id=a.job_id
        WHERE l.kind='merge' AND l.status='merged' AND l.created_at>=?1 AND l.created_at<?2
          AND j2.ticket_id IS NOT NULL)
     SELECT j.project AS project, j.ticket_id AS ticket_id, MIN(j.issue_created_at) AS issue_created_at
       FROM t JOIN jobs j ON j.project=t.project AND j.ticket_id=t.ticket_id
      WHERE j.issue_created_at IS NOT NULL
      GROUP BY j.project, j.ticket_id`,
    win.from, win.to);
  return { ok: true, merged: merges.length, ...filingToMerge(merges, artifacts, jobs) };
}

async function readSpend(db, win) {
  const tot = await db.prepare(
    `SELECT COUNT(*) AS calls, SUM(cost_usd IS NULL) AS unpriced_calls, SUM(cost_usd) AS usd
       FROM cost_rows WHERE ts>=?1 AND ts<?2`
  ).bind(win.from, win.to).first();
  const calls = Number(tot?.calls ?? 0);
  const unpriced = Number(tot?.unpriced_calls ?? 0);
  // 0 on a day with no calls; null when every call is unpriced (unknown, not free).
  const usd = calls === 0 ? 0 : unpriced === calls ? null : Number(tot.usd);
  // Its own count, so spend never leans on throughput's read succeeding.
  const merged = await count(db, `SELECT COUNT(*) AS n FROM ledgers WHERE kind='merge' AND status='merged' AND created_at>=?1 AND created_at<?2`,
    win.from, win.to);
  const top = await all(db,
    `SELECT project, ticket, SUM(cost_usd) AS usd, MAX(job_id) AS job_id FROM cost_rows
      WHERE ts>=?1 AND ts<?2 AND ticket IS NOT NULL AND cost_usd IS NOT NULL
      GROUP BY project, ticket ORDER BY usd DESC, project, ticket LIMIT ?3`,
    win.from, win.to, TOP_TICKETS + 1);
  return {
    ok: true,
    usd,
    calls,
    unpriced_calls: unpriced,
    usd_per_merged_pr: merged === 0 || usd === null ? null : usd / merged,
    top_tickets: capList(top, TOP_TICKETS),
  };
}

async function readAutonomy(db, win, opts) {
  const lim = opts.limit + 1;
  const w = [win.from, win.to];

  // Each predicate is spelled out in both its COUNT and its list read.
  const ejectN = await count(db,
    `SELECT COUNT(*) AS n FROM pr_state_events
      WHERE reason LIKE 'queue-ejected%' AND at>=?1 AND at<?2`, ...w);
  const batchN = await count(db,
    `SELECT COUNT(*) AS n FROM ledgers
      WHERE kind='batch_member' AND status IN ('red','abandoned') AND updated_at>=?1 AND updated_at<?2`, ...w);
  const dequeueRows = [
    ...await all(db,
      `SELECT 'pr_state_events' AS source, NULL AS project, repo || '#' || number AS key, at
         FROM pr_state_events
        WHERE reason LIKE 'queue-ejected%' AND at>=?1 AND at<?2
        ORDER BY at DESC, id DESC LIMIT ?3`, ...w, lim),
    ...await all(db,
      `SELECT 'batch_member' AS source, NULL AS project, key, updated_at AS at
         FROM ledgers
        WHERE kind='batch_member' AND status IN ('red','abandoned') AND updated_at>=?1 AND updated_at<?2
        ORDER BY updated_at DESC, key LIMIT ?3`, ...w, lim),
  ].sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));

  const reqN = await count(db,
    `SELECT COUNT(*) AS n FROM stage_events s
      WHERE s.verdict IN ('REQUEUED','RELEASED','DROPPED') AND s.actor IS NOT NULL
        AND TRIM(s.actor)<>'' AND LOWER(TRIM(s.actor))<>'jobs-watchdog'
        AND s.created_at>=?1 AND s.created_at<?2`, ...w);
  const reqRows = await all(db,
    `SELECT j.project AS project, COALESCE(j.ticket_id, s.job_id) AS key, s.verdict AS verdict,
            s.actor AS actor, s.created_at AS at
       FROM stage_events s LEFT JOIN jobs j ON j.id=s.job_id
      WHERE s.verdict IN ('REQUEUED','RELEASED','DROPPED') AND s.actor IS NOT NULL
        AND TRIM(s.actor)<>'' AND LOWER(TRIM(s.actor))<>'jobs-watchdog'
        AND s.created_at>=?1 AND s.created_at<?2
      ORDER BY s.created_at DESC, s.id DESC LIMIT ?3`, ...w, lim);

  // The nested CASE keeps a malformed detail from throwing and a string "3"
  // from comparing as TEXT above every integer.
  const loopN = await count(db,
    `SELECT COUNT(*) AS n FROM ledgers
      WHERE kind='br_record' AND updated_at>=?1 AND updated_at<?2
        AND (CASE WHEN json_valid(detail) THEN CASE WHEN json_type(detail,'$.rebuilds') IN ('integer','real')
             THEN json_extract(detail,'$.rebuilds') END END) >= ?3`, ...w, opts.loopMin);
  const loopRows = (await all(db,
    `SELECT key, json_extract(detail,'$.rebuilds') AS rebuilds, updated_at AS at
       FROM ledgers
      WHERE kind='br_record' AND updated_at>=?1 AND updated_at<?2
        AND (CASE WHEN json_valid(detail) THEN CASE WHEN json_type(detail,'$.rebuilds') IN ('integer','real')
             THEN json_extract(detail,'$.rebuilds') END END) >= ?3
      ORDER BY updated_at DESC, key LIMIT ?4`, ...w, opts.loopMin, lim))
    .map((r) => {
      const i = r.key.indexOf("/");
      return i < 0
        ? { project: null, key: r.key, rebuilds: r.rebuilds, at: r.at }
        : { project: r.key.slice(0, i), key: r.key.slice(i + 1), rebuilds: r.rebuilds, at: r.at };
    });
  const abandoned = await count(db,
    `SELECT COUNT(*) AS n FROM ledgers WHERE kind='abandoned' AND created_at>=?1 AND created_at<?2`, ...w);

  const by_table = {};
  for (const [table, sql] of ACTOR_TABLES) {
    const rows = await all(db, sql, ...w);
    by_table[table] = rows.reduce((n, r) => n + (isHumanActor(r.actor, opts.humanActors) ? Number(r.c) : 0), 0);
  }
  // BH-3905: only a proven human row counts: a human-token row whose human_sig
  // verifies under the worker key AND is the lowest id carrying that sig (a later
  // copy is a replay). No key: nothing can be proven, so 0. Capped at HUMAN_ROWS_MAX:
  // past it this counts only what it read, and says so in the log.
  by_table.verdicts = await provenHumanVerdicts(db, w, opts.sigKey);
  by_table.ticket_hold = await count(db,
    `SELECT COUNT(*) AS n FROM ledgers WHERE kind='ticket_hold' AND created_at>=?1 AND created_at<?2`, ...w);

  return {
    ok: true,
    batch_dequeues: { n: ejectN + batchN, basis: BATCH_BASIS, ...capList(dequeueRows, opts.limit) },
    manual_requeues: { n: reqN, ...capList(reqRows, opts.limit) },
    rebuild_loops: { n: loopN, abandoned, ...capList(loopRows, opts.limit) },
    human_interventions: { n: Object.values(by_table).reduce((a, b) => a + b, 0), by_table },
  };
}

// The MIN(id) per sig runs over the whole table, not the window: a whole-row
// replay copies created_at, so it lands in its original's window anyway, and a
// copy with an edited created_at no longer verifies. A subquery, not an IN list
// of binds: D1 refuses more than 100 bound values.
async function provenHumanVerdicts(db, w, sigKey) {
  if (!sigKey) return 0;
  let rows = await all(db,
    `SELECT id, repo, pr, head_sha, verdict, source, created_at, auth, human_sig
       FROM verdicts
      WHERE source='human' AND auth='human-token' AND human_sig IS NOT NULL
        AND created_at>=?1 AND created_at<?2
      ORDER BY id LIMIT ?3`, ...w, HUMAN_ROWS_MAX + 1);
  if (rows.length > HUMAN_ROWS_MAX) {
    console.warn(`[daily-digest] BH-3905 more than ${HUMAN_ROWS_MAX} signed human verdict rows in ${w[0]}..${w[1]}: counted the first ${HUMAN_ROWS_MAX} by id only`);
    rows = rows.slice(0, HUMAN_ROWS_MAX);
  }
  if (!rows.length) return 0;
  const first = new Map((await all(db,
    `SELECT human_sig, MIN(id) AS first_id FROM verdicts
      WHERE human_sig IN (SELECT human_sig FROM verdicts WHERE source='human' AND human_sig IS NOT NULL
                           AND created_at>=?1 AND created_at<?2)
      GROUP BY human_sig`, ...w)).map((r) => [r.human_sig, r.first_id]));
  let n = 0;
  for (const row of rows) {
    if (await humanProven(row, sigKey) === true && first.get(row.human_sig) === row.id) n += 1;
  }
  return n;
}

export async function readCoreSections(db, win, opts) {
  return {
    throughput: await section(() => readThroughput(db, win)),
    spend: await section(() => readSpend(db, win)),
    autonomy: await section(() => readAutonomy(db, win, opts)),
  };
}
