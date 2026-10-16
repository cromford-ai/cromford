// archive-read — one read over the hot store and, when the range can reach
// it, the archive store (env.ARCHIVE) too.
//
// The retention rules move old cost_rows and stage_events to the archive. A
// history reader whose window can reach past the move would otherwise answer
// short. This is the only module that reads env.ARCHIVE for a history read;
// a route runs its SQL through readHistory() and merges the two answers with
// mergeRows / mergeAggregate / mergeGroups. Nothing here writes.
//
// The decision rule, in order:
//   1. env.ARCHIVE has no prepare(): state "unbound", hot only, 0 archive calls.
//   2. `since` is at or after now - 1 day: "not-needed", 0 archive calls. An
//      archive rule never moves a row younger than 1 day.
//   3. Read the archive's newest time value (MAX_SQL). A missing table or a
//      NULL means nothing is archived: "not-needed".
//   4. `since` is after that value: "not-needed".
//   5. Else run the read on the archive too: "read".
//   6. Any other archive error at 3 or 5: the hot answer only, "unreadable",
//      logged. It is never thrown and never turned into an empty answer.

const DAY_MS = 86400e3;

// table -> the statement that reads its newest archived time. Constants, so
// no caller text reaches the archive's MAX read.
const MAX_SQL = Object.freeze({
  cost_rows: "SELECT MAX(ts) AS m FROM cost_rows",
  stage_events: "SELECT MAX(created_at) AS m FROM stage_events",
});

const run = (db, { sql, binds = [] }, method) => db.prepare(sql).bind(...binds)[method]();
const isNoTable = (e) => /no such table/i.test(String(e && e.message));

// readHistory(env, { table, since, now, hot, archive, method })
//   hot, archive: { sql, binds }; archive defaults to hot.
//   method: "all" (default) or "first".
// Returns { hot, archive, state }. `archive` is null unless state is "read".
// An error from the HOT read is thrown, as the route's own read would be.
export async function readHistory(env, { table, since, now, hot, archive = hot, method = "all" }) {
  const maxSql = MAX_SQL[table];
  if (!maxSql) throw new Error(`no archive time column for ${table}`);
  const hotAnswer = await run(env.DB, hot, method);
  const out = (state, arch = null) => ({ hot: hotAnswer, archive: arch, state });

  const A = env.ARCHIVE;
  if (!A || typeof A.prepare !== "function") return out("unbound");
  const sinceMs = Date.parse(since), nowMs = Date.parse(now);
  // An unparseable since falls through to the MAX read: the same SQL runs on
  // both stores, so the archive answers whatever the hot store answers.
  if (sinceMs >= nowMs - DAY_MS) return out("not-needed");

  let max;
  try {
    max = await A.prepare(maxSql).first();
  } catch (e) {
    if (isNoTable(e)) return out("not-needed");
    console.log(`archive-read: ${table} archive MAX unreadable: ${e && e.message}`);
    return out("unreadable");
  }
  const m = max ? max.m : null;
  if (m === null || m === undefined) return out("not-needed");
  if (sinceMs > Date.parse(m)) return out("not-needed");

  try {
    return out("read", await run(A, archive, method));
  } catch (e) {
    console.log(`archive-read: ${table} archive read unreadable: ${e && e.message}`);
    return out("unreadable");
  }
}

// mergeRows(hotRows, archRows, { key, compare, limit }) — concatenate, drop an
// archive row whose key is already in hot (the hot copy wins), sort, cap.
// No archive answer returns hotRows as they are.
export function mergeRows(hotRows, archRows, { key, compare, limit }) {
  if (!archRows) return hotRows;
  const seen = new Set(hotRows.map(key));
  return [...hotRows, ...archRows.filter((r) => !seen.has(key(r)))].sort(compare).slice(0, limit);
}

const pick = {
  sum: (a, b) => a + b,
  max: (a, b) => (b > a ? b : a),
  min: (a, b) => (b < a ? b : a),
};

// mergeAggregate(a, b, spec) — one row from two. spec: { column: sum|max|min }.
// NULL with NULL stays NULL; NULL with x is x. Columns not in spec come from a.
export function mergeAggregate(a, b, spec) {
  if (!b) return a;
  if (!a) return b;
  const out = { ...a };
  for (const [col, how] of Object.entries(spec)) {
    const x = a[col] ?? null, y = b[col] ?? null;
    out[col] = x === null ? y : y === null ? x : pick[how](x, y);
  }
  return out;
}

// mergeGroups(hotRows, archRows, { by, spec, pickBy, compare, limit }) —
// grouped rows merged on the `by` columns with mergeAggregate. Columns outside
// `by` and `spec` (bare columns) come from the row with the greater `pickBy`.
// Returns { rows, truncated }: truncated when the merge exceeds `limit`, or
// when either side returned `limit` rows (that side may lack a group that
// belongs in the top `limit`).
export function mergeGroups(hotRows, archRows, { by, spec, pickBy, compare, limit }) {
  if (!archRows) return { rows: hotRows, truncated: hotRows.length === limit };
  const k = (r) => JSON.stringify(by.map((c) => r[c] ?? null));
  const groups = new Map(hotRows.map((r) => [k(r), r]));
  for (const r of archRows) {
    const h = groups.get(k(r));
    if (!h) { groups.set(k(r), r); continue; }
    const newer = (r[pickBy] ?? "") > (h[pickBy] ?? "") ? r : h;
    groups.set(k(r), mergeAggregate({ ...newer }, newer === r ? h : r, spec));
  }
  const all = [...groups.values()].sort(compare);
  return {
    rows: all.slice(0, limit),
    truncated: all.length > limit || hotRows.length === limit || archRows.length === limit,
  };
}
