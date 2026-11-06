import { fmtNum, fmtUsd } from './format.js';

// BH-167.3: display rows for the ACCOUNT USAGE section. The payload is the
// worker's (GET /api/metrics/account-usage, `AccountUsageEntry` JSDoc in
// worker/jobs/src/lib/account-usage.js); nothing here computes a dollar. A
// null usd means nothing on that row is priced, so it stays null — the sort
// sinks it and the cell reads `—`, never $0.00.

export const USAGE_WINDOWS = [{ key: '5h', label: '5H' }, { key: '7d', label: '7D' }];

const NONE = '\u0000none';

export function fmtTokens(n) {
  if (n === null || n === undefined || !Number.isFinite(Number(n))) return '—';
  const v = Number(n);
  if (Math.abs(v) < 1000) return String(Math.round(v));
  if (Math.abs(v) < 1e6) return `${(v / 1000).toFixed(1)}k`;
  return `${fmtNum(v / 1e6, { decimals: 2 })}M`;
}

const pct = (n) => (n === null || n === undefined || !Number.isFinite(Number(n)) ? null : Number(n));
const pctText = (n) => (n === null ? '—' : `${n}%`);

function tokens(r) {
  return {
    calls: r.calls, unpriced: r.unpriced_calls,
    in: r.input_toks, out: r.output_toks, cr: r.cache_read, cw: r.cache_write,
    inText: fmtTokens(r.input_toks), outText: fmtTokens(r.output_toks),
    crText: fmtTokens(r.cache_read), cwText: fmtTokens(r.cache_write),
  };
}

export const accountKey = (acc) => acc.account ?? NONE;

export function crossCheckLine(acc) {
  const x = acc?.cross_check;
  if (!x) return '—';
  if (x.state === 'comparable') {
    const gap = x.gap_pct === null || x.gap_pct === undefined ? 'gap —' : `gap ${x.gap_pct}%`;
    return `meter ${fmtUsd(x.meter_delta_usd)} vs rows ${fmtUsd(x.rows_usd)}, ${gap}`;
  }
  return x.reason || x.state || '—';
}

export function usageRows(data) {
  if (!Array.isArray(data?.accounts)) return [];
  return data.accounts.map((acc) => {
    const sessionPct = pct(acc.meter?.session_pct);
    const weeklyPct = pct(acc.meter?.weekly_pct);
    return {
      key: accountKey(acc),
      label: acc.account ?? 'no account label',
      labelled: acc.account !== null && acc.account !== undefined,
      usd: acc.usd ?? null,
      usdText: fmtUsd(acc.usd),
      ...tokens(acc),
      sessionPct, weeklyPct,
      sessionText: pctText(sessionPct), weeklyText: pctText(weeklyPct),
      cross: crossCheckLine(acc),
      projects: (Array.isArray(acc.projects) ? acc.projects : []).map((p) => ({
        key: p.project ?? NONE,
        project: p.project ?? null,
        name: p.project ?? '(no project)',
        usd: p.usd ?? null,
        usdText: fmtUsd(p.usd),
        ...tokens(p),
      })),
      raw: acc,
    };
  });
}

export function unpricedBanner(data) {
  const n = Number(data?.totals?.unpriced_calls);
  if (!Number.isFinite(n) || !(n > 0)) return null;
  return n === 1
    ? '1 call in this window carries no price, so the dollar figures below undercount'
    : `${n} calls in this window carry no price, so the dollar figures below undercount`;
}
