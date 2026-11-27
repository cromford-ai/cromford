// The HISTORY period report (BH-9308, BH-9120.4). BH-9120.4 owns this file.
// totals = runs started in the period, clean and failed; series = runs per
// bucket; top rows = the newest
// mc.period.report_top_rows (fallback 20).
import { seriesBucket, logKnob } from '../../lib/log-period.js';

export const report = {
  title: 'HISTORY',
  load: async (api, period, knobs) => {
    const res = await api.periodGet('/api/cockpit/history',
      { ...period, keep: { totals: 1, series: seriesBucket(period, Date.now()), limit: logKnob(knobs, 'report_top_rows') } });
    return {
      totals: res.totals, series: res.series || [], topRows: res.runs || [],
      columns: ['id', 'project', 'kind', 'rc', 'started_at'],
      rowHref: (r) => `/runs/${encodeURIComponent(r.id)}`
    };
  }
};
