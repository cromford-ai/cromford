// BH-7876: the per-project daily spend ceilings, from the settings rows the
// harness reads (bin/lib/cost-budget.sh cost_budget_daily). Pure: no fetch, no
// DOM, so the tests drive it directly.
//
// A row is `conf.cost-caps.<project>.daily_usd` = `<usd>`, or the same key with
// a `.<box>` suffix for one box. The spend is GET
// /api/coord/metrics/llm-spend?project=<p> for the worker's current UTC day.

export const DAILY_WARN_KEY = 'conf.cost-caps.daily_warn_pct';
// The code fallback, the same as COST_BUDGET_DEFAULT_DAILY_WARN_PCT.
export const DEFAULT_DAILY_WARN_PCT = 80;

const KEY = /^conf\.cost-caps\.([a-z0-9_-]+)\.daily_usd(?:\.([a-z0-9_-]+))?$/;
const NUM = /^\d+(\.\d+)?$/;

const positive = (v) => {
  const s = String(v ?? '').trim();
  if (!NUM.test(s)) return null;
  const n = Number(s);
  return n > 0 ? n : null;
};

// dailyCeilingRows(settings) -> { rows, unreadable }. `settings` is the
// /api/coord/settings list. A value the harness would refuse is kept, with
// ceiling null, so the operator sees the row that does nothing.
export function dailyCeilingRows(settings) {
  if (!Array.isArray(settings)) return { rows: [], unreadable: true };
  const rows = [];
  for (const s of settings) {
    const m = KEY.exec(String(s?.key ?? ''));
    if (!m) continue;
    rows.push({
      key: s.key, project: m[1], box: m[2] ?? null,
      raw: s.value ?? null, ceiling: positive(s.value),
      actor: s.actor ?? null, updatedAt: s.updated_at ?? null,
    });
  }
  return { rows, unreadable: false };
}

export function dailyWarnPct(settings) {
  const row = Array.isArray(settings) ? settings.find((s) => s?.key === DAILY_WARN_KEY) : null;
  const n = row ? positive(row.value) : null;
  return n !== null && n <= 100 ? n : DEFAULT_DAILY_WARN_PCT;
}

// withSpend(rows, spendByProject, warnPct) -> rows with spent, pct, state, asOf.
// spendByProject[p] is the llm-spend answer, or { error } when the read
// failed. A failed read is `unknown` with spent null: never $0.
export function withSpend(rows, spendByProject, warnPct = DEFAULT_DAILY_WARN_PCT) {
  return rows.map((r) => {
    const s = spendByProject ? spendByProject[r.project] : undefined;
    const usd = s && typeof s.usd === 'number' && Number.isFinite(s.usd) ? s.usd : null;
    const base = { ...r, spent: usd, asOf: (s && s.as_of) || null, pct: null };
    if (r.ceiling === null) return { ...base, state: 'unreadable' };
    if (usd === null) return { ...base, state: 'unknown', error: (s && s.error) || 'no answer' };
    const pct = Math.floor((usd * 100) / r.ceiling);
    const state = usd >= r.ceiling ? 'over' : usd * 100 >= r.ceiling * warnPct ? 'warn' : 'under';
    return { ...base, pct, state };
  });
}
