import worker from '../../src/index.js';

export const SECRET = 'test-secret';
export const now = Date.now();  // determinism: ok the single anchor; every fixture below is iso(msAgo) off it
export const iso = (msAgo) => new Date(now - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');

export function hubLeaseWrite(state, rawSql, binds) {
  const sql = rawSql.replace(/\s+/g, ' ').trim();
  const bind = (tok) => {
    const m = /^\?(\d+)$/.exec(tok.trim());
    return m ? binds[Number(m[1]) - 1] : Number(tok.trim());
  };
  const row = state.hubLease || null;

  const up = /^UPDATE hub_lease SET (.+?) WHERE (.+)$/.exec(sql);
  if (up) {
    const [, set, where] = up;
    for (const pred of where.split(' AND ').map((x) => x.trim())) {
      let m;
      if (pred === 'id=1') { if (!row) return 0; continue; }
      if ((m = /^holder=\?(\d+)$/.exec(pred))) {
        if (!row || row.holder !== binds[Number(m[1]) - 1]) return 0;
      } else if ((m = /^epoch=\?(\d+)$/.exec(pred))) {
        if (!row || Number(row.epoch) !== Number(binds[Number(m[1]) - 1])) return 0;
      } else if ((m = /^expires_at > \?(\d+)$/.exec(pred))) {
        if (!row || !(String(row.expires_at) > String(binds[Number(m[1]) - 1]))) return 0;
      } else if ((m = /^expires_at <= \?(\d+)$/.exec(pred))) {
        if (!row || !(String(row.expires_at) <= String(binds[Number(m[1]) - 1]))) return 0;
      } else {
        throw new Error(`unmodelled hub_lease predicate: ${pred}`);
      }
    }
    if (!row) return 0;
    for (const asg of set.split(',').map((x) => x.trim())) {
      if (asg === 'epoch=epoch+1') { row.epoch = Number(row.epoch) + 1; continue; }
      const m = /^(\w+)=\?(\d+)$/.exec(asg);
      if (!m) throw new Error(`unmodelled hub_lease assignment: ${asg}`);
      row[m[1]] = binds[Number(m[2]) - 1];
    }
    return 1;
  }

  const ins = /^INSERT INTO hub_lease \(([^)]*)\) VALUES \(([^)]*)\) ON CONFLICT\(id\) DO (.+)$/.exec(sql);
  if (!ins) throw new Error(`unmodelled hub_lease statement: ${sql}`);
  const cols = ins[1].split(',').map((c) => c.trim());
  const vals = ins[2].split(',');
  const incoming = {};
  cols.forEach((c, i) => { incoming[c] = bind(vals[i]); });
  const tail = ins[3];
  if (/^NOTHING$/i.test(tail)) {
    if (row) return 0;
    state.hubLease = { ...incoming };
    return 1;
  }
  const doUpdate = /^UPDATE SET (.+)$/.exec(tail);
  if (!doUpdate) throw new Error(`unmodelled hub_lease conflict clause: ${tail}`);
  if (!row) { state.hubLease = { ...incoming }; return 1; }
  for (const asg of doUpdate[1].split(',').map((x) => x.trim())) {
    if (asg === 'epoch=hub_lease.epoch+1') { row.epoch = Number(row.epoch) + 1; continue; }
    const m = /^(\w+)=excluded\.(\w+)$/.exec(asg);
    if (!m) throw new Error(`unmodelled hub_lease conflict assignment: ${asg}`);
    row[m[1]] = incoming[m[2]];
  }
  return 1;
}


export function fakeDB(state) {
  const calls = [];
  const batches = [];
  const result = (sql, binds) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
    if (/FROM hub_lease/.test(sql)) {
      return { rows: state.hubLease ? [{ ...state.hubLease }] : [] };
    }
    // BH-482.3: the first-spawn watermark a build claim reads before it inserts.
    // Answered from the fixture rows FOR REAL, because the guarantee under test
    // is that a rebuild inherits the EARLIEST build row's instant for that exact
    // (project, ticket) — a stub answering "any job's created_at" would pass on
    // a worker that stamped every rebuild as its own first spawn.
    if (/SELECT MIN\(created_at\) AS first_spawn_at FROM jobs/.test(sql)) {
      if (state.minReadFails) throw new Error('D1_ERROR: no such column: first_spawn_at');
      const mins = (state.jobs || [])
        .filter((j) => j.project === binds[0] && j.ticket_id === binds[1] && j.kind === 'build')
        .map((j) => String(j.created_at))
        .sort();
      return { rows: [{ first_spawn_at: mins[0] ?? null }] };
    }
    if (/FROM jobs j LEFT JOIN job_heartbeats/.test(sql)) {
      const rows = /WHERE j\.id=/.test(sql)
        ? state.jobs.filter((j) => j.id === binds[0])
        : state.jobs;
      return { rows };
    }
    if (/SELECT [\w, *]+ FROM jobs WHERE id=/.test(sql)) {
      return { rows: state.jobs.filter((j) => j.id === binds[0]) };
    }
    if (/FROM job_phases/.test(sql)) {
      const rows = state.phases || [];
      if (/status='running'/.test(sql)) return { rows: rows.filter((p) => p.status === 'running') };
      if (/WHERE id=/.test(sql)) return { rows: rows.filter((p) => p.id === binds[0]) };
      // The terminal-marker probe. Filtered for real, because "a KILL_STOP is
      // terminal whatever the policy says" is a guarantee about WHICH phases
      // match, and a stub that returns every phase would prove it on rows that
      // carry no marker at all.
      if (/note LIKE/.test(sql)) {
        return { rows: rows.filter((p) => p.status === 'budget_stopped'
          || /KILL_STOP|BUDGET_STOP/.test(String(p.note || ''))) };
      }
      return { rows };
    }
    // --- phase 6 tables ------------------------------------------------------
    if (/FROM concurrency_rules WHERE/.test(sql)) {
      return { rows: (state.rules || []).filter((r) =>
        r.scope === binds[0] && r.selector === binds[1] && r.kind === binds[2]) };
    }
    if (/FROM concurrency_rules/.test(sql)) return { rows: state.rules || [] };
    if (/FROM retry_policies WHERE lane=/.test(sql)) {
      return { rows: (state.policies || []).filter((p) => p.lane === binds[0]) };
    }
    if (/FROM retry_policies/.test(sql)) return { rows: state.policies || [] };
    if (/FROM settings WHERE key=/.test(sql)) {
      return { rows: (state.settings || []).filter((r) => r.key === binds[0]) };
    }
    if (/FROM settings/.test(sql)) return { rows: state.settings || [] };
    if (/FROM job_claims WHERE job_id=/.test(sql)) {
      return { rows: (state.claims || []).filter((c) => c.job_id === binds[0]) };
    }
    // The peer queries the rule check runs, and the retry-pickup lookup. These
    // are filtered FOR REAL against the fixture rows rather than answered with
    // "everything": the whole point of a scope test is that a box rule counts
    // box peers and a repo rule counts repo peers, and a stub that returns the
    // same rows for both would pass on a worker that confused the two.
    if (/FROM jobs j/.test(sql) && !/LEFT JOIN job_heartbeats/.test(sql)) {
      const laneOf = (id) => ((state.claims || []).find((c) => c.job_id === id) || {}).lane;
      const literal = /j\.status='([^']+)'/.exec(sql);
      let rows = (state.jobs || []).slice();
      if (literal) rows = rows.filter((r) => r.status === literal[1]);
      const cmps = [...sql.matchAll(/(?:j|c)\.(\w+)(=|<>)\?/g)];
      cmps.forEach((m, i) => {
        const [, col, op] = m;
        const want = binds[i];
        rows = rows.filter((r) => {
          const actual = col === "lane" ? (laneOf(r.id) ?? null) : (r[col] ?? null);
          return op === "=" ? actual === want : actual !== want;
        });
      });
      if (/c\.attempts/.test(sql)) {
        rows = rows.map((r) => ({ ...r, ...((state.claims || []).find((c) => c.job_id === r.id) || {}) }));
      }
      return { rows };
    }
    // The live poll's read, modelled FOR REAL (BH-520): the cursor (`id > ?2`),
    // the job scope, the ascending order, the page cap and the `created_at AS at`
    // projection are the whole contract of the endpoint. A stub that answered
    // "every event" would pass on a route that replayed the entire log on every
    // poll. Rows written by older fixtures carry no `job_id`; those are left in
    // scope rather than dropped, so the pre-existing cases keep testing what
    // they were written to test.
    if (/FROM stage_events/.test(sql)) {
      let rows = (state.events || []).slice();
      if (/job_id=\?1/.test(sql)) {
        rows = rows.filter((e) => e.job_id === undefined || e.job_id === binds[0]);
      }
      if (/id > \?2/.test(sql)) rows = rows.filter((e) => Number(e.id) > Number(binds[1]));
      if (/ORDER BY id ASC/.test(sql)) rows = rows.sort((a, b) => Number(a.id) - Number(b.id));
      if (/created_at AS at/.test(sql)) {
        rows = rows.map(({ created_at, ...rest }) => ({ ...rest, at: created_at ?? null }));
      }
      const evLim = sql.match(/LIMIT (\d+)/);
      return { rows: evLim ? rows.slice(0, Number(evLim[1])) : rows };
    }
    if (/FROM ledgers/.test(sql)) return { rows: state.ledgers || [] };
    // Phase 7: the claim-time pause probe. Filtered FOR REAL against the binds,
    // because the guarantee under test is WHICH names a claim looks up — a stub
    // that answered "every flag row" would pass on a worker that paused the
    // fleet whenever any project was paused.
    if (/FROM pause_flags\s+WHERE active=1 AND name IN/.test(sql)) {
      return { rows: (state.flags || []).filter((f) => Number(f.active) === 1 && binds.includes(f.name)) };
    }
    if (/FROM pause_flags WHERE name=/.test(sql)) {
      return { rows: (state.flags || []).filter((f) => f.name === binds[0]) };
    }
    if (/FROM pause_flags/.test(sql)) return { rows: state.flags || [] };
    // Phase 7 tables.
    if (/FROM budget_catalog b LEFT JOIN budget_cap_flags/.test(sql)) {
      const row = (state.catalog || []).find((c) => c.lane === binds[0]);
      if (!row) return { rows: [] };
      const f = (state.capFlags || []).find((c) => c.lane === binds[0]);
      return { rows: [{ ...row, explicit: f ? Number(f.explicit) : 0, explicit_reason: f ? (f.reason || null) : null }] };
    }
    if (/FROM budget_cap_flags/.test(sql)) {
      const rows = state.capFlags || [];
      return { rows: /WHERE lane=/.test(sql) ? rows.filter((c) => c.lane === binds[0]) : rows };
    }
    if (/FROM phase_contracts/.test(sql)) {
      const rows = state.contracts || [];
      return { rows: /WHERE phase=/.test(sql) ? rows.filter((c) => c.phase === binds[0]) : rows };
    }
    // The artifact FEED (2026-09-10) — the join, modelled for real. The whole
    // point of the endpoint is the columns it folds on from `jobs` (box above
    // all: a sweep must skip its own builds), so a stub that answered bare
    // artifact rows would pass on a worker that never joined at all.
    if (/FROM job_artifacts a JOIN jobs j/.test(sql)) {
      let rows = (state.artifacts || []).map((a) => {
        const j = (state.jobs || []).find((x) => x.id === a.job_id) || {};
        return { ...a, project: j.project ?? null, ticket_id: j.ticket_id ?? null,
                 job_kind: j.kind ?? null, box: j.box ?? null, status: j.status ?? null };
      });
      for (const m of sql.matchAll(/(?:a|j)\.(\w+)(=|>)\?(\d+)/g)) {
        const want = binds[Number(m[3]) - 1];
        const col = m[1] === 'kind' ? 'job_kind' : m[1];
        rows = rows.filter((r) => m[2] === '='
          ? (r[col] ?? null) === want
          : String(r[col] ?? '') > String(want));
      }
      return { rows };
    }
    // The PR -> job resolution (BH-1024). Modelled FOR REAL — the filter AND the
    // ranking — because both are the whole contract: `a.artifact_ref=?1` is what
    // keeps one PR's verdict off another PR, and `build` before `review-verdict`
    // before newest is what stops a review lane's row becoming the standing
    // verdict of a build it does not own. Until this branch existed the query
    // fell through to the bare `FROM job_artifacts` one below (it says
    // `a LEFT JOIN` and `a.artifact_ref`, which neither older regex matches), so
    // every `/api/verdict` case here passed on an unfiltered `.first()`.
    if (/FROM job_artifacts a LEFT JOIN jobs j/.test(sql)) {
      const kindOf = (id) => String(((state.jobs || []).find((x) => x.id === id) || {}).kind ?? '');
      const rank = (id) => (kindOf(id) === 'build' ? 0 : kindOf(id) === 'review-verdict' ? 1 : 2);
      const rows = (state.artifacts || [])
        .filter((a) => a.artifact_kind === 'pr_url' && a.artifact_ref === binds[0])
        .slice()
        .sort((x, y) => rank(x.job_id) - rank(y.job_id)
          || String(y.updated_at ?? '').localeCompare(String(x.updated_at ?? ''))
          || String(y.job_id).localeCompare(String(x.job_id)));
      const lim = sql.match(/LIMIT (\d+)/);
      return { rows: lim ? rows.slice(0, Number(lim[1])) : rows };
    }
    if (/FROM job_artifacts/.test(sql)) {
      let rows = state.artifacts || [];
      if (/artifact_kind='pr_url' AND artifact_ref=/.test(sql)) {
        rows = rows.filter((a) => a.artifact_kind === 'pr_url' && a.artifact_ref === binds[0]);
      } else if (/WHERE job_id=\?1 AND artifact_kind=\?2/.test(sql)) {
        rows = rows.filter((a) => a.job_id === binds[0] && a.artifact_kind === binds[1]);
      } else if (/WHERE job_id=/.test(sql)) {
        rows = rows.filter((a) => a.job_id === binds[0]);
      }
      return { rows };
    }
    if (/FROM job_transcripts/.test(sql)) {
      let rows = state.transcripts || [];
      if (/AND phase_id=\?2 AND attempt=\?3/.test(sql)) {
        rows = rows.filter((x) => x.job_id === binds[0]
          && Number(x.phase_id) === Number(binds[1]) && Number(x.attempt) === Number(binds[2]));
      } else if (/WHERE job_id=/.test(sql)) {
        rows = rows.filter((x) => x.job_id === binds[0]);
      }
      // The index projection is a real part of the contract, not a detail: the
      // job-detail poll must not carry bodies. Modelled here so a query that
      // quietly went back to SELECT * would show up as a body in the response.
      if (!/SELECT \*/.test(sql)) rows = rows.map(({ body, ...rest }) => rest);
      return { rows };
    }

    // Pre-plans (BH-658). Filtered FOR REAL on the binds, because every
    // guarantee here is about WHICH row a reader is handed: a relay that
    // fetched a different ticket's plan is the TK-493 shape with a whole
    // design attached, and a stub answering "any preplan row" would pass on a
    // worker that never filtered at all.
    if (/FROM preplans/.test(sql)) {
      let rows = (state.preplans || []).slice();
      if (/WHERE project=\?1 AND ticket_key=\?2/.test(sql)) {
        rows = rows.filter((r) => r.project === binds[0] && r.ticket_key === binds[1]);
      } else if (/WHERE project=\?1/.test(sql)) {
        rows = rows.filter((r) => r.project === binds[0]);
      }
      if (/ORDER BY updated_at DESC/.test(sql)) {
        rows = rows.sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
      }
      // The index projection is part of the contract, not a detail: the hub
      // reads it once per candidate per tick, and a plan body on that read
      // would be megabytes an hour for a list of file paths.
      if (!/SELECT \*/.test(sql) && !/plan_md/.test(sql)) {
        rows = rows.map(({ plan_md, ...rest }) => rest);
      }
      const ppLim = sql.match(/LIMIT (\d+)/);
      return { rows: ppLim ? rows.slice(0, Number(ppLim[1])) : rows };
    }

    // Metrics ledger (2026-08-29). Filtered for real on the key columns: the
    // guarantee under test is that a write is an UPSERT on the row's natural
    // key, and a stub that answered "the same row for any bind" would pass on a
    // worker that keyed burn_days on the server clock instead of the day.
    if (/FROM burn_days/.test(sql)) {
      const rows = state.burnDays || [];
      return { rows: /WHERE day=/.test(sql) ? rows.filter((r) => r.day === binds[0]) : rows };
    }
    if (/FROM pr_costs/.test(sql)) return { rows: state.prCosts || [] };
    // The column self-migration probe (2026-09-02): the fixture names which
    // columns pr_costs already has, so a test can prove the ALTER happens
    // exactly when a column is missing and never when it is there.
    if (/PRAGMA table_info\(pr_costs\)/.test(sql)) {
      return { rows: (state.prCostsCols || []).map((name) => ({ name })) };
    }
    // Same probe, second table (2026-09-06, outcome_metrics.repairs).
    if (/PRAGMA table_info\(outcome_metrics\)/.test(sql)) {
      return { rows: (state.outcomeCols || []).map((name) => ({ name })) };
    }
    // Third table (2026-09-14, the cost_rows session + attribution columns).
    // Defaults to the FULL set, so the many cost-rows tests that do not care
    // about migration see no ALTERs; a test names a shorter list to prove one.
    if (/PRAGMA table_info\(cost_rows\)/.test(sql)) {
      const cols = state.costRowsCols || [
        'box', 'row_hash', 'line_no', 'ts', 'host', 'project', 'stage', 'runner', 'model',
        'rc', 'duration_s', 'input_toks', 'output_toks', 'cache_read', 'cache_write',
        'cost_usd', 'billing_mode', 'auth_fp', 'auth_account',
        'session_id', 'row_source', 'result_usd', 'ticket', 'job_id', 'pr', 'run_id',
        'note', 'raw', 'inserted_at', 'lane_id',  // lane_id: BH-2303
        'guard_fp',   // TEST-CHANGE BH-2537: 25 -> 26 (the full set gains guard_fp)
        'participant'];  // TEST-CHANGE BH-5349: the full set gains participant (ADDED_COLUMNS.cost_rows)
      return { rows: cols.map((name) => ({ name })) };
    }
    // ...and fourth (2026-09-14, the meter's extra_limit_usd/extra_pct/status).
    if (/PRAGMA table_info\(extra_usage_snapshots\)/.test(sql)) {
      return { rows: (state.snapshotCols || []).map((name) => ({ name })) };
    }
    // Fifth table (2026-09-17, BH-482.0's jobs.issue_created_at/first_spawn_at).
    // Defaults to the FULL set like cost_rows does, so the many claim tests see
    // no ALTERs; a test names a shorter list to prove one.
    if (/PRAGMA table_info\(jobs\)/.test(sql)) {
      const cols = state.jobsCols || [
        'id', 'project', 'ticket_id', 'kind', 'box', 'stage', 'status',
        'budget_usd', 'spent_usd', 'created_at', 'updated_at', 'meta',
        'issue_created_at', 'first_spawn_at'];
      return { rows: cols.map((name) => ({ name })) };
    }
    // Sixth table (2026-09-22, BH-1026.0's build_queue.machine). The enqueue and
    // the release both NAME the column now — they clear it — so they widen the
    // table first. Defaults to the FULL set like jobs does, so the many queue
    // tests see no ALTER; a test names a shorter list to prove one.
    if (/PRAGMA table_info\(build_queue\)/.test(sql)) {
      const cols = state.buildQueueCols || [
        'project', 'ticket_key', 'ticket_id', 'status', 'target', 'attempt',
        'requested_by', 'claimed_by', 'claimed_at', 'enqueued_at', 'finished_at',
        'reason', 'meta', 'updated_at', 'machine', 'harness_commit'];
      return { rows: cols.map((name) => ({ name })) };
    }
    if (/FROM cost_rows/.test(sql)) return { rows: state.costRows || [] };
    if (/FROM model_prices/.test(sql)) return { rows: state.modelPrices || [] };
    if (/FROM cli_versions/.test(sql)) return { rows: state.cliVersions || [] };
    if (/FROM box_status/.test(sql)) return { rows: state.boxStatus || [] };
    if (/FROM extra_usage_snapshots/.test(sql)) {
      const rows = state.snapshots || [];
      if (/WHERE box=\?1 AND ts=\?2/.test(sql)) {
        return { rows: rows.filter((r) => r.box === binds[0] && r.ts === binds[1]) };
      }
      if (/WHERE box=/.test(sql)) return { rows: rows.filter((r) => r.box === binds[0]) };
      return { rows };
    }
    // Cost reconciliation (2026-09-14). Filtered for real on the WHERE the
    // handler builds, because the guarantee under test is that the read narrows
    // by account/state/since — a stub answering every row would pass on a worker
    // whose filters never reached the query.
    if (/FROM cost_reconciliation/.test(sql)) {
      let rows = state.reconciliations || [];
      // [\s\S] because the handler's template literal puts ORDER BY on the next
      // line, and a `.` that stops at the newline would quietly filter nothing.
      const m = sql.replace(/\s+/g, ' ').match(/WHERE ([\s\S]+?) ORDER BY/);
      if (m) {
        m[1].split(' AND ').forEach((clause, i) => {
          const col = clause.split(/[=><]/)[0];
          if (/>=/.test(clause)) rows = rows.filter((r) => String(r[col] ?? '') >= binds[i]);
          else rows = rows.filter((r) => (r[col] ?? null) === binds[i]);
        });
      }
      return { rows };
    }
    if (/FROM outcome_metrics/.test(sql)) return { rows: state.outcomes || [] };
    // Flaky CI (2026-09-12). Filtered for real on repo and day, because the
    // guarantee under test is that the READ is what narrows the window — three
    // consumers (the known-flake set, the quarantine proposer, the 7d rate)
    // ask for a repo and a since and trust the answer not to carry the rest.
    if (/FROM ci_flakes/.test(sql)) {
      let rows = state.flakes || [];
      const m = sql.match(/WHERE (.+?) ORDER BY/);
      if (m) {
        m[1].split(' AND ').forEach((clause, i) => {
          if (/^repo=/.test(clause)) rows = rows.filter((r) => r.repo === binds[i]);
          if (/^day>=/.test(clause)) rows = rows.filter((r) => String(r.day || '') >= binds[i]);
        });
      }
      return { rows };
    }
    // SDLC item 2: the review gate. Filtered for real on the repo, because the
    // guarantee under test is that the write is an upsert keyed on the repo and
    // that a GET names the row it hands back.
    if (/FROM review_gate_thresholds/.test(sql)) {
      const rows = state.thresholds || [];
      return { rows: /WHERE scope=/.test(sql) ? rows.filter((r) => r.scope === binds[0]) : rows };
    }
    if (/FROM review_gate/.test(sql)) {
      const rows = state.gates || [];
      return { rows: /WHERE repo=/.test(sql) ? rows.filter((r) => r.repo === binds[0]) : rows };
    }
    // Lane liveness (2026-08-30). Filtered for real on (project, box), because
    // the guarantee under test is that a lane is keyed on the PAIR — a stub
    // answering "any lane row" would pass on a worker that beat every box's
    // lane whenever one of them ticked.
    if (/FROM lanes/.test(sql)) {
      const rows = state.lanes || [];
      if (/WHERE project=\?1 AND box=\?2/.test(sql)) {
        return { rows: rows.filter((r) => r.project === binds[0] && r.box === binds[1]) };
      }
      return { rows };
    }
    // The pre-claim build queue (2026-09-10). Filtered FOR REAL on the binds and
    // on the literal status, because every guarantee under test here is about
    // WHICH row a claim takes: the oldest, of the right target, that is still
    // `queued`. A stub answering "any queue row" would pass on a worker that
    // handed the same build to two dispatchers.
    // The merge queue (2026-09-10). Filtered for real on the binds and the
    // literal status, because the guarantees under test are which rows a list
    // returns and in what ORDER — a queue that reorders landings is a different
    // queue, and a stub answering "any row" would pass on one that did.
    if (/FROM merge_queue/.test(sql)) {
      let rows = (state.mergeQueue || []).slice();
      for (const m of sql.matchAll(/(\w+)=\?(\d+)/g)) {
        const want = binds[Number(m[2]) - 1];
        rows = rows.filter((r) => String(r[m[1]] ?? '') === String(want));
      }
      if (/ORDER BY enqueued_at ASC, pr ASC/.test(sql)) {
        rows = rows.sort((a, b) => String(a.enqueued_at).localeCompare(String(b.enqueued_at))
          || Number(a.pr) - Number(b.pr));
      } else if (/ORDER BY enqueued_at ASC/.test(sql)) {
        rows = rows.sort((a, b) => String(a.enqueued_at).localeCompare(String(b.enqueued_at)));
      }
      return { rows };
    }
    if (/FROM build_queue/.test(sql)) {
      let rows = (state.queue || []).slice();
      const lit = /status='([^']+)'/.exec(sql);
      if (lit) rows = rows.filter((r) => r.status === lit[1]);
      // NOT IN (?2,?3,…) — the exclusion the claim walk re-queries with. Without
      // it the stub hands back a row the walk has already skipped, so a worker
      // that never advanced would look identical to one that did.
      const notIn = /ticket_key NOT IN \(([^)]*)\)/.exec(sql);
      if (notIn) {
        const excluded = notIn[1].split(",").map((ph) => binds[Number(ph.trim().slice(1)) - 1]);
        rows = rows.filter((r) => !excluded.includes(r.ticket_key));
      }
      for (const m of sql.matchAll(/(\w+)=\?(\d+)/g)) {
        const want = binds[Number(m[2]) - 1];
        rows = rows.filter((r) => (r[m[1]] ?? null) === want);
      }
      // reason LIKE ?n OR reason LIKE ?m — the deferral filter. Emulated rather
      // than ignored: "which rows come back" is the whole claim, and a stub that
      // handed back every row would prove it against rows that do not match.
      const likes = [...sql.matchAll(/reason LIKE \?(\d+)/g)]
        .map((m) => String(binds[Number(m[1]) - 1]));
      if (likes.length) {
        rows = rows.filter((r) => likes.some((pat) => new RegExp(
          `^${pat.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*")}$`, "s")
          .test(String(r.reason ?? ""))));
      }
      // `[\s\S]*` because the claim's ORDER BY now opens with a hotfix rank
      // expression that spans lines (BH-645). This stub still sorts on
      // enqueued_at only, which is what these rows exercise — none of them
      // carries hotfix meta. The rank itself is proven against real SQLite in
      // test/queue-priority.test.js rather than emulated here.
      if (/ORDER BY [\s\S]*enqueued_at ASC/.test(sql)) {
        rows = rows.sort((a, b) => String(a.enqueued_at).localeCompare(String(b.enqueued_at)));
      }
      if (/LIMIT 1$/.test(sql.trim())) rows = rows.slice(0, 1);
      return { rows };
    }
    // The wake feed (2026-09-12). Filtered FOR REAL on the binds and on the
    // literal `acked_at IS NULL`, because both guarantees under test are about
    // WHICH rows a loop is handed: a bare GET owes it the unacked backlog, and
    // a ?since query owes it everything past its own watermark whether or not
    // an ack ever landed. A stub answering "any wake row" would pass on a
    // worker that re-handed a loop work it had already run.
    if (/FROM wakes/.test(sql)) {
      let rows = (state.wakes || []).slice();
      if (/acked_at IS NULL/.test(sql)) rows = rows.filter((r) => !r.acked_at);
      const gt = /id > \?(\d+)/.exec(sql);
      if (gt) rows = rows.filter((r) => Number(r.id) > Number(binds[Number(gt[1]) - 1]));
      for (const m of sql.matchAll(/(repo|kind)=\?(\d+)/g)) {
        const want = binds[Number(m[2]) - 1];
        rows = rows.filter((r) => String(r[m[1]] ?? '') === String(want));
      }
      return { rows: rows.sort((a, b) => Number(a.id) - Number(b.id)) };
    }
    if (/GROUP BY day, project, kind/.test(sql)) return { rows: state.burn || [] };

    // BH-433 coordination tables
    if (/FROM pr_owners/.test(sql)) {
      let rows = (state.prOwners || []).slice();
      if (/WHERE repo=\?1/.test(sql)) rows = rows.filter((r) => r.repo === binds[0]);
      if (/closed_at IS NULL/.test(sql)) rows = rows.filter((r) => r.closed_at === null || r.closed_at === undefined);
      if (/ORDER BY number ASC/.test(sql)) rows = rows.sort((a, b) => Number(a.number) - Number(b.number));
      const prLim = sql.match(/LIMIT (\d+)/);
      return { rows: prLim ? rows.slice(0, Number(prLim[1])) : rows };
    }
    if (/FROM decisions/.test(sql)) {
      let rows = (state.decisions || []).slice();
      const limMatch = sql.match(/LIMIT (\d+)/);
      const lim = limMatch ? Number(limMatch[1]) : 1000;
      const projMatch = sql.match(/project=\?(\d+)/);
      const stampMatch = sql.match(/stamp>=\?(\d+)/);
      if (projMatch) rows = rows.filter((r) => r.project === binds[Number(projMatch[1]) - 1]);
      if (stampMatch) rows = rows.filter((r) => String(r.stamp || '') >= binds[Number(stampMatch[1]) - 1]);
      if (/ORDER BY stamp ASC, id ASC/.test(sql)) {
        rows = rows.sort((a, b) => String(a.stamp).localeCompare(String(b.stamp))
          || Number(a.id || 0) - Number(b.id || 0));
      }
      return { rows: rows.slice(0, lim) };
    }
    if (/FROM findings/.test(sql)) {
      let rows = (state.findings || []).slice();
      const limMatch = sql.match(/LIMIT (\d+)/);
      const lim = limMatch ? Number(limMatch[1]) : 1000;
      const projMatch = sql.match(/project=\?(\d+)/);
      const stampMatch = sql.match(/stamp>=\?(\d+)/);
      if (projMatch) rows = rows.filter((r) => r.project === binds[Number(projMatch[1]) - 1]);
      if (stampMatch) rows = rows.filter((r) => String(r.stamp || '') >= binds[Number(stampMatch[1]) - 1]);
      if (/ORDER BY stamp ASC, id ASC/.test(sql)) {
        rows = rows.sort((a, b) => String(a.stamp).localeCompare(String(b.stamp))
          || Number(a.id || 0) - Number(b.id || 0));
      }
      return { rows: rows.slice(0, lim) };
    }
    if (/FROM telegram_topics/.test(sql)) return { rows: state.topics || [] };

    return { rows: [] };
  };
  const stmt = (sql) => ({
    bind: (...binds) => ({
      // Carried so `batch` can record what it was handed. A batched statement
      // is bound and then never run individually, so without this the calls log
      // is empty for every batch route and a test asserting "one upsert per row"
      // would pass against a worker that sent nothing at all.
      _sql: sql, _binds: binds,
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => {
        // preplans is modelled as a real table, mutated in place, so the route's
        // own read-back sees what it just wrote and a SECOND publish for the
        // same ticket is provably a REPLACEMENT rather than a second row.
        if (/INSERT INTO preplans/.test(sql)) {
          const rows = state.preplans || (state.preplans = []);
          const row = { project: binds[0], ticket_key: binds[1], base_sha: binds[2],
            ticket_fp: binds[3], planned_files: binds[4], plan_md: binds[5],
            bytes: binds[6], box: binds[7], created_at: binds[8], updated_at: binds[8],
            thread_at: binds[9] === undefined ? null : binds[9] };
          const at = rows.findIndex((r) => r.project === row.project && r.ticket_key === row.ticket_key);
          if (at >= 0) rows.splice(at, 1, { ...row, created_at: rows[at].created_at });
          else rows.push(row);
        }
        // The lease's CAS ladder is judged by the fixture row, not by a stub.
        if (/hub_lease/.test(sql)) {
          result(sql, binds);
          return { meta: { changes: hubLeaseWrite(state, sql, binds) } };
        }
        result(sql, binds);
        // `casLost` models the row moving under us between the read and the
        // compare-and-swap: SQLite reports zero rows changed, and the loser of
        // the race has to notice.
        const lost = (state.queueCasLoseKeys
            && /UPDATE build_queue SET status='claimed'/.test(sql)
            && state.queueCasLoseKeys.includes(binds[1]))
          || (state.casLost && /AND status='queued_for_retry'/.test(sql))
          // Same model for the build queue's claim: the row moved between the
          // read and the compare-and-swap, so SQLite changed nothing and the
          // second dispatcher has to notice rather than build the same ticket.
          || (state.queueCasLost && /UPDATE build_queue SET status='claimed'/.test(sql));
        // The wake dedupe, modelled: ON CONFLICT DO NOTHING changed zero rows,
        // which is the ONLY way the receiver can tell a redelivery from a new
        // press of the doorbell.
        const noop = lost || (state.wakesInsertNoop && /INSERT INTO wakes/.test(sql));
        return { meta: { changes: noop ? 0 : 1, last_row_id: 1 } };
      }
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => { result(sql, []); return { meta: { changes: 1, last_row_id: 1 } }; }
  });
  return {
    prepare: stmt,
    batch: async (xs) => {
      batches.push(xs.map((x) => ({ sql: x._sql.replace(/\s+/g, ' ').trim(), binds: x._binds })));
      return xs.map((x) => {
        result(x._sql, x._binds);
        let changes = 1;
        if (/INSERT OR IGNORE INTO decisions/.test(x._sql)) {
          const b = x._binds;
          const exists = (state.decisions || []).some((d) => d.project === b[1] && d.stamp === b[0] && d.line === b[5]);
          if (exists) changes = 0;
        }
        if (/INSERT OR IGNORE INTO findings/.test(x._sql)) {
          const b = x._binds;
          const exists = (state.findings || []).some((d) => d.project === b[1] && d.stamp === b[0] && d.line === b[4]);
          if (exists) changes = 0;
        }
        // pr_owners is modelled as a real table, mutated in place, so a second
        // PUT in the same test sees what the first one wrote: "PUT again -> no
        // second insert" is a claim about rows, not about SQL text.
        if (/INSERT INTO pr_owners/.test(x._sql)) {
          const b = x._binds;
          const rows = state.prOwners || (state.prOwners = []);
          const row = { repo: b[0], number: b[1], project: b[2], state: b[3], since: b[4],
            reason: b[5], key: b[6], url: b[7], author: b[8], draft: b[9], dirty_since: b[10],
            closed_at: null, actor: b[11], updated_at: b[12] };
          const at = rows.findIndex((r) => r.repo === row.repo && r.number === row.number);
          if (at >= 0) rows.splice(at, 1, row); else rows.push(row);
        }
        if (/UPDATE pr_owners SET closed_at/.test(x._sql)) {
          const stamp = x._binds[0];
          const repo = x._binds[1];
          const nums = x._binds.slice(2);
          const byNumber = /number NOT IN/.test(x._sql);
          const byStamp = /updated_at<\?1/.test(x._sql);
          const doomed = (state.prOwners || []).filter((r) => r.repo === repo
            && (r.closed_at === null || r.closed_at === undefined)
            && (!byNumber || !nums.includes(r.number))
            && (!byStamp || String(r.updated_at || '') < String(stamp)));
          doomed.forEach((r) => { r.closed_at = stamp; });
          changes = doomed.length;
        }
        return { meta: { changes } };
      });
    },
    _calls: calls,
    _batches: batches
  };
}


export const call = (path, { method = 'GET', body, secret = SECRET, state = {} } = {}) => {
  const db = fakeDB({ jobs: [], ...state });
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db
  }));
};

export const RUNNING = (over) => ({
  id: 'build-project-3-TK-1-1', project: 'project-3', kind: 'build', stage: 'execute',
  box: 'box-project-3-2', ticket_id: 'TK-1', status: 'running',
  budget_usd: 150, spent_usd: 4.12, created_at: iso(3600e3), updated_at: iso(1800e3),
  ...over
});

export const CLAIM = (over) => ({
  method: 'POST',
  body: { project: 'project-3', kind: 'build', box: 'box-project-3-2', stage: 'plan',
    ticket_id: 'TK-70', lane: 'plan/project-3/claude', ...over }
});

export const RULE = (scope, selector, kind, max) => ({ scope, selector, kind, max_concurrent: max, note: null });

export const POLICY = (over) => ({ lane: 'plan/project-3/*', max_attempts: 3, backoff_seconds: 600,
  escalate_allowed: 0, note: null, ...over });

export const LANE = { lane: 'execute/project-3/claude', budget_usd: 12.5, updated_at: iso(0) };

export const TR = (over) => ({
  job_id: 'build-project-3-TK-1-1', phase_id: 7, attempt: 1, stage: 'execute',
  runner: 'claude', model: 'claude-opus-5', source: 'session_jsonl',
  bytes: 1200, truncated: 0, redactions: 2, body: 'the whole conversation',
  actor: 'box-project-3-2', created_at: iso(60e3), updated_at: iso(60e3),
  ...over
});

export const sqlOf = (db, re) => db._calls.filter((c) => re.test(c.sql));

export const insertOf = (db) => db._calls.find((c) => /INSERT INTO jobs/.test(c.sql));

export { worker };
