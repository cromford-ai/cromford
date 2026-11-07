// worker/jobs/test/lib/hot-scan.bh-9076.js — the scan rule of the BH-9076
// hot-statements EXPLAIN test, kept out of src/ on purpose: it judges plans,
// it never runs in the worker.
//
// The rule is the BH-6727 noFullScan rule, made alias-aware. A plan line
// `SCAN <t>` where <t> is a hot table (or an alias of one in the statement)
// is a full read of the table or of one of its indexes, and fails. A
// `SEARCH ...` line passes. A `SCAN` of a table that is not hot (a summary
// table, json_each, a materialized CTE) passes. Any `CORRELATED` line fails:
// a correlated subquery re-runs per outer row.

// The hot tables of the 2026-10-14 incident (BH-6727 HOT), the five big ones
// plus job_artifacts, which the 6727 suite also counts.
export const HOT_TABLES = ['wakes', 'cost_rows', 'jobs', 'job_heartbeats', 'ledgers', 'job_artifacts'];

const NOT_ALIAS = new Set(['WHERE', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'CROSS', 'ON', 'GROUP', 'ORDER',
  'LIMIT', 'USING', 'AS', 'WITH', 'UNION', 'HAVING', 'NATURAL', 'INDEXED', 'NOT', 'SELECT', 'SET']);

// aliasesOf(sql) — { name -> table } for every `FROM t [AS] a` / `JOIN t [AS] a`,
// with each table also mapped to itself.
export function aliasesOf(sql) {
  const out = {};
  const re = /\b(?:FROM|JOIN)\s+(\w+)(?:\s+(?:AS\s+)?(\w+))?/gi;
  for (const m of sql.matchAll(re)) {
    out[m[1]] = m[1];
    if (m[2] && !NOT_ALIAS.has(m[2].toUpperCase())) out[m[2]] = m[1];
  }
  return out;
}

// failingLines(lines, {aliases, allow, hot}) — the plan lines that break the
// rule. `allow` is a list of regexes for a SCAN line a caller has argued is
// bounded (the 6727 jobs list walk that stops at its LIMIT).
export function failingLines(lines, { aliases = {}, allow = [], hot = HOT_TABLES } = {}) {
  return lines.filter((l) => {
    if (/CORRELATED/.test(l)) return true;
    const m = /^SCAN (\w+)/.exec(l);
    if (!m) return false;
    const table = aliases[m[1]] || m[1];
    return hot.includes(table) && !allow.some((a) => a.test(l));
  });
}

// normalizeSql(sql) — the statement shape: string and number literals become
// `?`, whitespace collapses, case folds. Two texts with one shape are one
// statement for the fixture's distinct count.
export function normalizeSql(sql) {
  return sql.replace(/'(?:[^']|'')*'/g, '?').replace(/\b\d+\b/g, '?').replace(/\s+/g, ' ').trim().toLowerCase();
}
